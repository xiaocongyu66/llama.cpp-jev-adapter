# JoyFox JEV support in llama.cpp

This repository adapts llama.cpp itself to load and execute JoyFox `Qwen3.5-0.8B-JEV` as a decision model. It does not turn the checkpoint into a text-generation model and does not modify the checkpoint. The source patch adds native GGUF decision-head tensors and server-side `choice`, `noul`, and `score` scoring using the learned query/key projections.

The scoring rule is:

```text
q = Wq * h_decision + bq
k_i = Wk * h_option_i + bk
logit_i = dot(q, k_i) / sqrt(128)
probabilities = softmax(logits)
```

Each question is evaluated independently with the JoyFox reference row layout: shared state, one question, its candidate spans, then the decision suffix. The hidden size is 1024 and the decision head size is 128.

## Build and test

No model weights or generated GGUF files are stored in this repository. GitHub Actions checks out the pinned llama.cpp source, applies `patches/jev-llama.cpp.patch`, builds `llama-server` on the GitHub runner, downloads the public JoyFox checkpoint at a pinned revision, converts it for the integration test, and runs the `/v1/systemone` test. The checkpoint and converted test model remain on the ephemeral runner and are not uploaded as artifacts.

The local workspace is used only to edit and review the source patch. Do not run a local CMake, Make, or Ninja build for this project.
