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

# Service Account para los jobs de Vertex
SA_NAME="vertex-train-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Tu usuario humano (para evitar el 403 al leer/editar IAM del bucket)
USER_EMAIL="naat.lab.ia@gmail.com"

# Buckets (usa nombres reales, únicos a nivel global)
DATA_BUCKET="tu-bucket-datos"       # lectura de datos
STAGING_BUCKET="tu-bucket-staging"  # escritura de artefactos/resultados

### =========================
echo "[1/9] Set project"
gcloud config set project "${PROJECT_ID}" >/dev/null

### =========================
echo "[2/9] Enable required APIs (idempotente)"
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iamcredentials.googleapis.com

### =========================
echo "[3/9] Create Service Account (si no existe)"
if ! gcloud iam service-accounts list --format="value(email)" | grep -q "^${SA_EMAIL}$"; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Vertex Training SA"
else
  echo "  SA ya existe: ${SA_EMAIL}"
fi

### =========================
echo "[4/9] Grant minimal project roles to SA (idempotente)"
# Nota: evitamos storage.admin/object* a nivel PROYECTO; daremos acceso por BUCKET más abajo.
for ROLE in \
  roles/bigquery.jobUser \
  roles/bigquery.dataEditor \
  roles/artifactregistry.reader \
  roles/logging.logWriter \
  roles/monitoring.metricWriter
do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" >/dev/null || true
done

### =========================
echo "[5/9] Allow Vertex AI to impersonate the SA"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser" >/dev/null || true

### =========================
echo "[6/9] (Opcional) IAM a nivel dataset de BigQuery"
bq add-iam-policy-binding "${PROJECT_ID}:${BQ_DATASET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" 2>/dev/null || true
bq add-iam-policy-binding "${PROJECT_ID}:${BQ_DATASET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser" 2>/dev/null || true

### =========================
echo "[7/9] Create buckets (idempotentes) y IAM específico"
if [ -n "${DATA_BUCKET}" ]; then
  # Crear bucket si no existe (nota: usar --pap en vez de --public-access-prevention)
  gcloud storage buckets create "gs://${DATA_BUCKET}" \
    --location="${BQ_LOCATION}" \
    --uniform-bucket-level-access \
    --pap enforced >/dev/null || true

  # (Opcional) si tu cuenta humana no tiene permisos para ver/editar la policy,
  # primero date roles/storage.admin a nivel proyecto o bucket:
  # gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  #   --member="user:${USER_EMAIL}" --role="roles/storage.admin" || true

  # Permisos bucket-level:
  gcloud storage buckets add-iam-policy-binding "gs://${DATA_BUCKET}" \
    --member="user:${USER_EMAIL}" \
    --role="roles/storage.admin" >/dev/null || true

  gcloud storage buckets add-iam-policy-binding "gs://${DATA_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectViewer" >/dev/null || true
fi

if [ -n "${STAGING_BUCKET}" ]; then
  gcloud storage buckets create "gs://${STAGING_BUCKET}" \
    --location="${BQ_LOCATION}" \
    --uniform-bucket-level-access \
    --pap enforced >/dev/null || true

  gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="user:${USER_EMAIL}" \
    --role="roles/storage.admin" >/dev/null || true

  gcloud storage buckets add-iam-policy-binding "gs://${STAGING_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectAdmin" >/dev/null || true
fi

### =========================
echo "[8/9] Create BigQuery dataset (idempotente)"
bq --location="${BQ_LOCATION}" mk -d "${PROJECT_ID}:${BQ_DATASET}" 2>/dev/null || true

### =========================
echo "[9/9] Create BigQuery tables con schema (idempotente)"
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

# Verificación opcional (debería mostrar política sin 403):
# gcloud storage buckets get-iam-policy "gs://${DATA_BUCKET}" || true
# gcloud storage buckets get-iam-policy "gs://${STAGING_BUCKET}" || true
