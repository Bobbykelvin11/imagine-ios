# Imagine 2.0

Grok-Imagine-style AI images and videos for iPhone (iOS 17+), **free and online**, built only on open-source models.

**Images** (auto fallback, no account needed)
1. Z-Image Turbo (Tongyi-MAI) on a free Hugging Face ZeroGPU Space: photoreal, ~6–12 s
2. FLUX.1 schnell / FLUX.1 dev (Black Forest Labs Spaces)
3. Pollinations classic endpoint (no key: 1 image / 45 s per IP) or your own Pollinations key
4. AI Horde volunteer GPUs (anonymous ≤ 576×576, or your free key)
5. Your own server: Automatic1111/Forge API or ComfyUI (API-format workflow with placeholders)

Photo edits ("image to image") use FLUX.1 Kontext dev (HF Space), then AI Horde img2img.

**Video**
- LTX-2.3 (Lightricks) HF Space: text-to-video and image-to-video **with sound**, 2–5 s, ~25–60 s wait
- LTX-Video distilled HF Space: text-to-video fallback
- Your own ComfyUI (Wan 2.x / LTX-Video workflow)
- On-device clip maker (AVFoundation): zoom & pan or morph between images, unlimited and offline

**Quotas**: Hugging Face ZeroGPU gives ~2 min GPU/day unauthenticated (per IP) and ~5 min/day with a free
account token (Settings → Hugging Face). Spaces can be busy, paused or changed by their owners.

UX: prompt bar with Image/Video mode, aspect ratios, 1–4 images per prompt, live job tiles with queue position,
infinite feed, tap → Make video / Edit / More like this / Save to Photos / Share, history in Gallery.

An optional offline mode (Apple ml-stable-diffusion + Core ML models downloaded in-app) is in Settings.

The online engine (`Imagine/Online/Core`) is a plain Swift package: `swift test` runs its unit tests.
Unsigned IPA is built by GitHub Actions (`.github/workflows/build-ipa.yml`); sign it with Sideloadly/AltStore.
