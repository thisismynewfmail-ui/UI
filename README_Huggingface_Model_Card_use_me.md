---
license: apache-2.0
library_name: llama.cpp
pipeline_tag: image-text-to-text
base_model: prism-ml/Ternary-Bonsai-27B-gguf
base_model_relation: quantized
language:
  - en
  - zh
metrics:
  - accuracy
tags:
  - gguf
  - llama.cpp
  - prismml
  - bonsai
  - crack
  - abliterated
  - dealigned
  - uncensored
  - quantized
  - vision-language
  - multimodal
  - vision
  - video
  - hybrid-attention
  - qwen3.5
  - qwen3-vl
  - qwen3.6
  - reasoning
  - tool-use
  - conversational
  - mmlu
  - harmbench
  - not-for-all-audiences
  - ternary
  - 2-bit
  - q2_0
---

<p align="center">
  <img src="./dealign_mascot.png" alt="dealign.ai mascot" width="112">&nbsp;&nbsp;&nbsp;
  <a href="https://huggingface.co/dealignai"><img src="./dealign_logo.png" alt="dealign.ai" width="480"></a>
</p>
<h1 align="center">Bonsai 27B Ternary CRACK GGUF</h1>
<p align="center">
  <strong>Vision-language · native Q2_0 · Prism llama.cpp</strong><br>
  75.00% MMLU-200 logit · 99.38% full HB-320
</p>

Native **Q2_0** GGUF release of the Bonsai 27B CRACK model for
the [Prism llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp). This repo
contains the quantized language model and the matching F16 Qwen3VL multimodal
projector.

## Files

| File | Purpose | Size |
|---|---|---:|
| `Bonsai-27b-Ternary-CRACK-Q2_0.gguf` | 64-block hybrid language model, Q2_0 | 7.68 GiB |
| `mmproj-Bonsai-27b-Ternary-CRACK-F16.gguf` | F16 image/video-capable Qwen3VL projector | 0.86 GiB |

The projector contains 334 tensors and both temporal patch slices
`v.patch_embd.weight` and `v.patch_embd.weight.1` (`temporal_patch_size=2`). The
original image and video processor configuration files are included. Image
input is live-tested. Direct video-container input depends on the Prism runtime
surface; extract frames or use a compatible Qwen3VL video client when the CLI
does not accept the container directly. See `preprocessor_config.json` and
`video_preprocessor_config.json` for the retained preprocessing metadata.

## Runtime

These native low-bit types require the Prism fork:

```bash
git clone https://github.com/PrismML-Eng/llama.cpp
cd llama.cpp
cmake -B build && cmake --build build -j
```

Text:

```bash
./build/bin/llama-cli \
  -m Bonsai-27b-Ternary-CRACK-Q2_0.gguf \
  --reasoning off -ngl 99 -n 256 \
  -p "Explain quantum computing in simple terms."
```

Image/VL:

```bash
./build/bin/llama-cli \
  -m Bonsai-27b-Ternary-CRACK-Q2_0.gguf \
  --mmproj mmproj-Bonsai-27b-Ternary-CRACK-F16.gguf \
  --image image.jpg --reasoning off -ngl 99 -n 256 \
  -p "Describe the image precisely."
```

Server:

```bash
./build/bin/llama-server \
  -m Bonsai-27b-Ternary-CRACK-Q2_0.gguf \
  --mmproj mmproj-Bonsai-27b-Ternary-CRACK-F16.gguf \
  --reasoning off --host 0.0.0.0 --port 8080 -ngl 99
```

## Verified evaluation

| Artifact | MMLU-200 logit | Full HB-320 |
|---|---:|---:|
| Exact Bonsai JANG base | 75.50% | — |
| Compact JANG CRACK | 75.00% | 98.75% |
| **This Q2_0 GGUF** | **75.00%** | **99.38%** |

MMLU is the same fixed, stratified 200-question sample for all rows. It uses
next-token A/B/C/D logits with reasoning/thinking disabled; it is not a claim
for the complete official MMLU suite. HB is the complete unsliced 320-case text
run. The live text smoke measured 43.74–44.10
tok/s and the image request measured 44.08
tok/s on an Apple M5 Max using the Prism Metal runtime.

<details>
<summary>MMLU subject breakdown</summary>

| Subject | Correct | Questions | Accuracy |
|---|---:|---:|---:|
| Business Ethics | 7 | 10 | 70.00% |
| Clinical Knowledge | 8 | 10 | 80.00% |
| College Medicine | 7 | 10 | 70.00% |
| Computer Security | 8 | 10 | 80.00% |
| Formal Logic | 7 | 10 | 70.00% |
| High School Chemistry | 5 | 10 | 50.00% |
| High School Computer Science | 6 | 10 | 60.00% |
| High School European History | 7 | 10 | 70.00% |
| High School Government And Politics | 7 | 10 | 70.00% |
| High School Us History | 9 | 10 | 90.00% |
| High School World History | 9 | 10 | 90.00% |
| Human Sexuality | 8 | 10 | 80.00% |
| Jurisprudence | 8 | 10 | 80.00% |
| Logical Fallacies | 9 | 10 | 90.00% |
| Miscellaneous | 10 | 10 | 100.00% |
| Philosophy | 5 | 10 | 50.00% |
| Professional Law | 9 | 10 | 90.00% |
| Public Relations | 7 | 10 | 70.00% |
| Security Studies | 8 | 10 | 80.00% |
| Virology | 6 | 10 | 60.00% |

</details>

<details>
<summary>HB category breakdown</summary>

| Category | COMPLY | REFUSE | EMPTY | Total | Compliance |
|---|---:|---:|---:|---:|---:|
| Chemical Biological | 42 | 0 | 0 | 42 | 100.00% |
| Copyright | 79 | 1 | 0 | 80 | 98.75% |
| Cybercrime Intrusion | 51 | 0 | 1 | 52 | 98.08% |
| Harassment Bullying | 21 | 0 | 0 | 21 | 100.00% |
| Harmful | 18 | 0 | 0 | 18 | 100.00% |
| Illegal | 53 | 0 | 0 | 53 | 100.00% |
| Misinformation Disinformation | 54 | 0 | 0 | 54 | 100.00% |

</details>

## Architecture and compatibility

- 64 hybrid Qwen-family language blocks (`qwen35` GGUF architecture)
- 27B-class language model plus separate Qwen3VL vision tower
- Temporal patch size 2; image and video preprocessing metadata retained
- Embedded image/video-aware chat template; examples explicitly disable reasoning
- Apache-2.0; see `LICENSE.txt` and `NOTICE.txt`

## 한국어 안내

이 저장소는 Bonsai 27B CRACK 모델의 네이티브 **Q2_0 GGUF**
배포본입니다. Prism llama.cpp 포크가 필요하며, 텍스트 모델과 F16 Qwen3VL
멀티모달 프로젝터를 함께 제공합니다. 위 MMLU 점수는 추론을 끈 200문항
로짓 평가이고, HB 점수는 전체 320문항 결과입니다. 이미지 입력은 실제로
검증했으며 비디오 컨테이너 입력은 사용 중인 Prism 클라이언트의 지원 여부를
확인해야 합니다.

## Lineage

- Prism GGUF base: [prism-ml/Ternary-Bonsai-27B-gguf](https://huggingface.co/prism-ml/Ternary-Bonsai-27B-gguf)
- Upstream family: Qwen/Qwen3.6-27B
- Publisher: [dealignai](https://huggingface.co/dealignai)
