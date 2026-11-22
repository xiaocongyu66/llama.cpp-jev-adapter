# JoyFox JEV support in llama.cpp

This repository contains the complete llama.cpp source tree in `llama.cpp/`, with native JoyFox `Qwen3.5-0.8B-JEV` decision-model support. It does not turn the checkpoint into a text-generation model or modify the checkpoint. The source adds native GGUF decision-head tensors and server-side `choice`, `noul`, and `score` scoring using the learned query/key projections.

The scoring rule is:

```text
q = Wq * h_decision + bq
k_i = Wk * h_option_i + bk
logit_i = dot(q, k_i) / sqrt(128)
probabilities = softmax(logits)
```

Each question is evaluated independently with the JoyFox reference row layout: shared state, one question, its candidate spans, then the decision suffix. The hidden size is 1024 and the decision head size is 128.

## Build and test

GitHub Actions builds the source in `llama.cpp/`, downloads the public JoyFox checkpoint at a pinned revision, converts it for the integration test, and runs the `/v1/systemone` test. The checkpoint and converted test model remain on the ephemeral runner and are not uploaded as artifacts.
