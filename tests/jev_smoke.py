import argparse
import json
import time
import urllib.error
import urllib.request


def request_json(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    args = parser.parse_args()

    for _ in range(120):
        try:
            request_json(args.base_url + "/health")
            break
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2)
    else:
        raise RuntimeError("llama-server did not become healthy")

    record = {
        "state": "Customer was charged twice and requests a refund.",
        "questions": {
            "route": {
                "type": "choice",
                "instructions": "Which team should handle this ticket?",
                "criteria": {"billing": "Payments, invoices, or refunds", "account": "Account access"},
            },
            "refund": {"type": "noul", "instructions": "Does the customer request a refund?"},
            "urgency": {
                "type": "score",
                "instructions": "How urgent is the issue?",
                "criteria": ["Normal queue", "Priority", "Immediate"],
            },
        },
    }
    result = request_json(args.base_url + "/v1/systemone", record)["answers"]
    for key, question_type in (("route", "choice"), ("refund", "noul"), ("urgency", "score")):
        answer = result[key]
        assert answer["type"] == question_type, (key, answer)
        if question_type == "noul":
            assert 0.0 <= answer["noul"] <= 1.0, answer
            continue
        probabilities = answer["probabilities"]
        assert abs(sum(probabilities.values()) - 1.0) < 1e-5, answer
        if question_type == "choice":
            assert answer["choice"] in probabilities, answer
        else:
            assert 0.0 <= answer["score"] <= 2.0, answer


if __name__ == "__main__":
    main()
