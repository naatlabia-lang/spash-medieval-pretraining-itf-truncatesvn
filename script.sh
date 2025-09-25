#!/usr/bin/env bash
set -euo pipefail

### =========================
### CONFIG (edita aquí)
### =========================
PROJECT_ID="naat-lab-ai"
REGION="us-central1"
BQ_LOCATION="US"

BQ_DATASET="nlp_metrics"
BQ_TRIALS_TABLE="tfidf_svd_trials"
BQ_BEST_TABLE="tfidf_svd_best"

# Service Account
SA_NAME="vertex-train-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# (Opcional) buckets
DATA_BUCKET="tu-bucket-datos"          # donde está tu CSV, solo lectura
STAGING_BUCKET="tu-bucket-staging"     # donde el job escribirá resultados

### =========================
echo "[1/7] Set project"
gcloud config set project "${PROJECT_ID}" >/dev/null

### =========================
echo "[2/7] Enable required APIs (idempotente)"
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iamcredentials.googleapis.com

### =========================
echo "[3/7] Create Service Account (si no existe)"
if ! gcloud iam service-accounts list --format="value(email)" | grep -q "^${SA_EMAIL}$"; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Vertex Training SA"
else
  echo "  SA ya existe: ${SA_EMAIL}"
fi

### =========================
echo "[4/7] Grant roles to SA (proyecto) - idempotente"
for ROLE in \
  roles/bigquery.jobUser \
  roles/bigquery.dataEditor \
  roles/storage.objectViewer \
  roles/storage.objectAdmin \
  roles/artifactregistry.reader \
  roles/logging.logWriter \
  roles/monitoring.metricWriter
do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" >/dev/null || true
done

### (Opcional) IAM a nivel dataset de BigQuery (además de los roles de proyecto)
echo "[4b/7] (Opcional) Bindings de dataset BigQuery"
bq add-iam-policy-binding "${PROJECT_ID}:${BQ_DATASET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" 2>/dev/null || true
bq add-iam-policy-binding "${PROJECT_ID}:${BQ_DATASET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser" 2>/dev/null || true

### =========================
echo "[5/7] Create buckets (opcionales, idempotentes)"
if [ -n "${DATA_BUCKET}" ]; then
  gsutil mb -l "${BQ_LOCATION}" -b on "gs://${DATA_BUCKET}" 2>/dev/null || true
  gsutil iam ch "serviceAccount:${SA_EMAIL}:objectViewer" "gs://${DATA_BUCKET}" >/dev/null || true
fi
if [ -n "${STAGING_BUCKET}" ]; then
  gsutil mb -l "${BQ_LOCATION}" -b on "gs://${STAGING_BUCKET}" 2>/dev/null || true
  gsutil iam ch "serviceAccount:${SA_EMAIL}:objectAdmin" "gs://${STAGING_BUCKET}" >/dev/null || true
fi

### =========================
echo "[6/7] Create BigQuery dataset (idempotente)"
bq --location="${BQ_LOCATION}" mk -d "${PROJECT_ID}:${BQ_DATASET}" 2>/dev/null || true

### =========================
echo "[7/7] Create BigQuery tables con schema (idempotente)"
TMP_DIR="$(mktemp -d)"
cat > "${TMP_DIR}/trials_schema.json" <<'EOF'
[
  {"name":"job_name","type":"STRING"},
  {"name":"timestamp","type":"TIMESTAMP"},
  {"name":"has_labels","type":"BOOL"},
  {"name":"analyzer","type":"STRING"},
  {"name":"ngram_range","type":"STRING"},
  {"name":"min_df","type":"FLOAT"},
  {"name":"max_df","type":"FLOAT"},
  {"name":"max_features","type":"INT64"},
  {"name":"n_components","type":"INT64"},
  {"name":"mean_test_f1_macro","type":"FLOAT"},
  {"name":"mean_test_var_exp","type":"FLOAT"},
  {"name":"rank","type":"INT64"},
  {"name":"is_best","type":"BOOL"}
]
EOF

cat > "${TMP_DIR}/best_schema.json" <<'EOF'
[
  {"name":"job_name","type":"STRING"},
  {"name":"timestamp","type":"TIMESTAMP"},
  {"name":"has_labels","type":"BOOL"},
  {"name":"best_params_json","type":"STRING"},
  {"name":"best_index","type":"INT64"},
  {"name":"best_f1_macro","type":"FLOAT"},
  {"name":"best_var_exp","type":"FLOAT"}
]
EOF

# Crear tablas (si no existen)
bq --location="${BQ_LOCATION}" mk -t \
  --schema="${TMP_DIR}/trials_schema.json" \
  "${PROJECT_ID}:${BQ_DATASET}.${BQ_TRIALS_TABLE}" 2>/dev/null || true

bq --location="${BQ_LOCATION}" mk -t \
  --schema="${TMP_DIR}/best_schema.json" \
  "${PROJECT_ID}:${BQ_DATASET}.${BQ_BEST_TABLE}" 2>/dev/null || true

echo "==============================================="
echo "Listo ✅"
echo "Proyecto:     ${PROJECT_ID}"
echo "SA:           ${SA_EMAIL}"
echo "Dataset BQ:   ${BQ_DATASET} (loc=${BQ_LOCATION})"
echo "Tablas BQ:    ${BQ_TRIALS_TABLE}, ${BQ_BEST_TABLE}"
[ -n "${DATA_BUCKET}" ]   && echo "Data bucket:  gs://${DATA_BUCKET}"
[ -n "${STAGING_BUCKET}" ]&& echo "Staging:      gs://${STAGING_BUCKET}"
echo "==============================================="
