"""UniMacHub's speaker for HolosTTS, the Ukrainian voices.

Runs in UniMacHub's own Python environment and talks over its standard input and output:
one JSON request per line in, one JSON answer per line out. Everything libraries print goes
to standard error, so the answers stay clean. The model stays loaded between requests.

Requests:
  {"id": 1, "cmd": "ready"}                       load (downloading the model the first time)
  {"id": 2, "cmd": "say", "text": "...", "voice": "name", "speed": 1.0, "out": "/path.wav"}
  {"id": 3, "cmd": "clone", "audio": "/path.wav", "name": "My voice"}
  {"id": 4, "cmd": "forget", "name": "My voice"}
"""

import json
import os
import re
import sys
from unicodedata import normalize

ANSWERS = sys.stdout
sys.stdout = sys.stderr

HOME = os.environ.get("UNIMACHUB_HOLOS_HOME", os.path.expanduser("~/Library/Application Support/UniMacHub/Voices/holos"))
CUSTOM = os.path.join(HOME, "custom")
GENDERS = os.path.join(HOME, "genders.json")
os.makedirs(CUSTOM, exist_ok=True)

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from holos.models import HolosTTS, VoiceEncoder  # noqa: E402
from ipa_uk import ipa  # noqa: E402
from ukrainian_word_stress import Stressifier, StressSymbol  # noqa: E402

DEVICE = "cpu"
SAMPLE_RATE = 24000
model = None
encoder = None
stressify = None


def answer(request, **fields):
    fields["id"] = request.get("id")
    ANSWERS.write(json.dumps(fields, ensure_ascii=False) + "\n")
    ANSWERS.flush()


def parts(text):
    """Sentences, as the demo splits them: the model reads one at a time."""
    text = re.sub(r"(\w+[^.,!:?\-])\n", r"\1. ", text).replace("\n", " ")
    pieces, current = [], ""
    for index, symbol in enumerate(text):
        current += symbol
        if symbol in ".?!:" and index < len(text) - 1 and text[index + 1] == " " and len(current) > 100:
            pieces.append(current)
            current = ""
    pieces.append(current)
    return [piece.strip() for piece in pieces if piece.strip()]


def phonemes(sentence):
    sentence = sentence.replace('"', "").replace("+", StressSymbol.CombiningAcuteAccent)
    sentence = normalize("NFKC", sentence)
    sentence = re.sub(r"[᠆‐‑‒–—―⁻₋−⸺⸻]", "-", sentence)
    if sentence[-1] not in ".?!:-":
        sentence += "."
    sentence = re.sub(r" - ", ": ", sentence)
    return ipa(stressify(sentence))


def custom_voices():
    return {name[:-4]: os.path.join(CUSTOM, name) for name in sorted(os.listdir(CUSTOM)) if name.endswith(".npy")}


def voice_for(name):
    custom = custom_voices()
    if name in custom:
        return torch.from_numpy(np.load(custom[name])).float()
    return name


def speak(text, voice, speed):
    audio = []
    with torch.inference_mode():
        for sentence in parts(text):
            sounds = phonemes(sentence)
            if sounds:
                audio.append(model.generate(sounds, voice_for(voice), speed=speed).squeeze().cpu())
    if not audio:
        return None
    data = torch.cat(audio).numpy()
    peak = np.abs(data).max() or 1.0
    return (data / peak * 0.95).astype(np.float32)


def pitch(data):
    """The median pitch of the voiced parts, in hertz."""
    import librosa

    f0 = librosa.yin(data, fmin=60, fmax=400, sr=SAMPLE_RATE)
    rms = librosa.feature.rms(y=data, frame_length=2048, hop_length=512)[0]
    voiced = f0[: len(rms)][rms[: len(f0)] > rms.mean() * 0.5]
    return float(np.median(voiced)) if len(voiced) else 0.0


def gender_of(voice):
    """Heard, not guessed from the name: below about 165 Hz a voice reads as a man's."""
    data = speak("Добрий день! Як ваші справи сьогодні?", voice, 1.0)
    return "male" if data is not None and 0 < pitch(data) < 165 else "female"


def genders():
    try:
        with open(GENDERS) as file:
            return json.load(file)
    except (OSError, ValueError):
        return {}


def save_genders(known):
    with open(GENDERS, "w") as file:
        json.dump(known, file, ensure_ascii=False)


def voice_list():
    known = genders()
    names = list(model.voices.keys()) + list(custom_voices().keys())
    changed = False
    for name in names:
        if name not in known:
            known[name] = gender_of(name)
            changed = True
    if changed:
        save_genders(known)
    custom = set(custom_voices().keys())
    return [{"name": name, "gender": known[name], "custom": name in custom} for name in names]


def handle(request):
    global model, encoder, stressify
    command = request.get("cmd")
    if command == "ready":
        if model is None:
            stressify = Stressifier()
            model = HolosTTS("patriotyk/HolosTTS", device=DEVICE)
        answer(request, ok=True, voices=voice_list())
    elif command == "say":
        data = speak(request["text"], request.get("voice"), float(request.get("speed", 1.0)))
        if data is None:
            answer(request, ok=False, error="nothing to say")
        else:
            sf.write(request["out"], data, SAMPLE_RATE)
            answer(request, ok=True)
    elif command == "clone":
        if encoder is None:
            encoder = VoiceEncoder("patriotyk/HolosTTS", device=DEVICE)
        with torch.inference_mode():
            vector = encoder.encode(request["audio"]).squeeze(0).cpu().numpy()
        name = re.sub(r"[/\\:]", "-", request["name"]).strip() or "My voice"
        np.save(os.path.join(CUSTOM, name + ".npy"), vector)
        known = genders()
        known[name] = gender_of(name)
        save_genders(known)
        answer(request, ok=True, name=name, gender=known[name])
    elif command == "forget":
        path = custom_voices().get(request.get("name", ""))
        if path:
            os.remove(path)
        answer(request, ok=True)
    else:
        answer(request, ok=False, error="unknown command")


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        request = json.loads(line)
    except ValueError:
        continue
    try:
        handle(request)
    except Exception as error:  # noqa: BLE001
        answer(request, ok=False, error=f"{type(error).__name__}: {error}")
