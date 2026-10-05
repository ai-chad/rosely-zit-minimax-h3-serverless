# Unified credential replacement patch

Target repository:
`ai-chad/rosely-zit-minimax-h3-serverless`

Replace:
- `provision.sh`
- `scripts/start_model_server.sh`
- `.env.example`

Do not replace:
- `worker.py`
- `model_server.py`

New canonical credential names:
- `AWS_UNIFIED_ACCESS_KEY_ID`
- `AWS_UNIFIED_SECRET_ACCESS_KEY`
- optional `AWS_UNIFIED_SESSION_TOKEN`

Why this works:
- `provision.sh` explicitly exports the unified values into the standard boto3
  `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` names before the pinned
  provisioning core runs.
- `scripts/start_model_server.sh` repeats the mapping before Uvicorn imports
  `model_server.py`.
- Old cached `AWS_ZIT_IMAGE_*` and `ROSELY_ZIT_S3_*` credential aliases are
  explicitly unset so they cannot override the unified credentials.
- Shared bucket/region variables overwrite old family-specific bucket values.

Shared S3:
- `ROSELY_S3_BUCKET=rosely-infrastructure`
- `ROSELY_S3_REGION=us-east-1`

Recommended base image:
`vastai/pytorch:cuda-13.0.3-auto`

Recommended disk:
`200 GB`

Pinned provisioning core:
`e5afd4e0fe39ff03170a5aaa075b3936b8afd060`
