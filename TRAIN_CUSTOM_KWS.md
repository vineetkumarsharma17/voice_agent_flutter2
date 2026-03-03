# How to Train a Custom KWS Model for "stop", "hold on", etc.

## Prerequisites
- Linux machine (or WSL on Windows)
- Python 3.8+
- PyTorch
- 16GB+ RAM recommended

## Steps

### 1. Clone Icefall Repository
```bash
git clone https://github.com/k2-fsa/icefall
cd icefall
pip install -r requirements.txt
```

### 2. Prepare Your Keywords File
Create `custom_keywords.txt`:
```
stop
hold on
pause
cancel
wait
go
start
resume
```

### 3. Download Training Data
You need speech data. Options:
- **LibriSpeech** (free, English): https://www.openslr.org/12
- **GigaSpeech** (larger, better quality)
- Or record your own voice samples

### 4. Train the Model
```bash
cd egs/librispeech/ASR/zipformer_kws

# Modify the keywords file
cp /path/to/custom_keywords.txt data/kws_keywords.txt

# Start training (takes several hours/days on GPU)
./train.py \
  --world-size 1 \
  --num-epochs 30 \
  --start-epoch 1 \
  --exp-dir zipformer_kws \
  --max-duration 300
```

### 5. Export to ONNX
```bash
./export-onnx.py \
  --epoch 30 \
  --avg 9 \
  --exp-dir zipformer_kws \
  --tokens data/lang_bpe_500/tokens.txt \
  --keywords data/kws_keywords.txt
```

This generates:
- `encoder.onnx`
- `decoder.onnx`
- `joiner.onnx`
- `tokens.txt`
- `keywords.txt`

### 6. Use in Your App
Replace the files in `assets/models/kws/` with your newly trained model files.

---

## Easier Alternative: Use Existing Models + Text-Based Detection

Since training takes time and resources, I recommend:

**Keep using KWS for wake words** (like "Hello World", "Hey Siri")
**Use text-based interruption for stop commands** (already works!)

The text-based approach in your Voice Agent screen works perfectly for "stop", "hold on", etc., and requires zero model training.

---

## Pre-trained Models Available

Check if any of these models already have your keywords:
- https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models

Look for models trained on:
- Wenetspeech (Chinese + some English)
- Gigaspeech (English, general purpose)

Unfortunately, most pre-trained KWS models focus on wake words ("Hey Siri", "OK Google") rather than command words ("stop", "pause").

---

## Quick Solution for Your Use Case

**Recommended approach:**

1. **Use KWS screen** for wake word detection (already working!)
   - "Hello World"
   - "Hey Siri"
   - etc.

2. **Use Voice Agent screen with "Voice Interruption" enabled** for command detection
   - "stop"
   - "hold on"
   - "pause"
   - "cancel"
   - "wait"

This gives you the best of both worlds without needing to train a custom model!
