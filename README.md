# Imagine

On-device, offline text-to-image for iPhone (iOS 17+), built on Apple's open-source
[ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) Swift package.

- Download Core ML Stable Diffusion models in the app (SD 2.1, SD 1.5, Realistic Vision 5.1,
  Dreamlike Photoreal 2.0, SDXL for iOS) or add any Core ML model from Hugging Face / a zip / Files.
- Prompt, negative prompt, steps, guidance, seed, sampler, batch of up to 4, image-to-image.
- No safety checker: it is never downloaded or loaded.
- Gallery with save to Photos, share, reuse prompt.
- Optional Video tab: open-source Wan 2.2 / LTX-Video on fal.ai with your own API key (stored in Keychain).

Unsigned IPA is built by GitHub Actions (`.github/workflows/build-ipa.yml`); sign it with Sideloadly/AltStore/SideStore.
