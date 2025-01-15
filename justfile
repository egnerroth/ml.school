set dotenv-load
set export
set positional-arguments

KERAS_BACKEND := "jax"
MLFLOW_TRACKING_URI := "http://127.0.0.1:5000"

default:
    @just --list

# Run project unit tests
test:
    uv run -- pytest

# Display version of required dependencies
[group('setup')]
@dependencies:
    uv_version=$(uv --version) && \
        just_version=$(just --version) && \
        docker_version=$(docker --version | awk '{print $3}' | sed 's/,//') && \
        jq_version=$(jq --version | awk -F'-' '{print $2}') && \
    echo "uv: $uv_version" && \
    echo "just: $just_version" && \
    echo "docker: $docker_version" && \
    echo "jq: $jq_version"

# Run MLflow server
[group('setup')]
@mlflow:
    uv run -- mlflow server --host 127.0.0.1 --port 5000

# Set up required environment variables
[group('setup')]
@env:
    echo "KERAS_BACKEND=$KERAS_BACKEND\nMLFLOW_TRACKING_URI=$MLFLOW_TRACKING_URI" > .env
    cat .env


# Run training pipeline
[group('training')]
@train:
    uv run -- python pipelines/training.py --environment=conda run

# Run training pipeline card server 
[group('training')]
@train-viewer:
    uv run -- python pipelines/training.py --environment=conda card server

# Serve latest registered model locally
[group('serving')]
@serve:
    uv run -- mlflow models serve \
        -m models:/penguins/$(curl -s -X GET "$MLFLOW_TRACKING_URI/api/2.0/mlflow/registered-models/get-latest-versions" \
        -H "Content-Type: application/json" -d '{"name": "penguins"}' \
        | jq -r '.model_versions[0].version') -h 0.0.0.0 -p 8080 --no-conda

# Invoke local running model with sample request
[group('serving')]
@invoke:
    uv run -- curl curl -X POST http://0.0.0.0:8080/invocations \
        -H "Content-Type: application/json" \
        -d '{"inputs": [{ \
            "island": "Biscoe", \
            "culmen_length_mm": 48.6, \
            "culmen_depth_mm": 16.0, \
            "flipper_length_mm": 230.0, \
            "body_mass_g": 5800.0, \
            "sex": "MALE" \
        }]}'

# Display number of records in SQLite database
[group('serving')]
@sqlite:
    uv run -- sqlite3 penguins.db "SELECT COUNT(*) FROM data;"

# Generate fake traffic to local running model
[group('monitoring')]
@traffic:
    uv run -- python pipelines/traffic.py --environment=conda run --samples 200

# Generate fake labels in SQLite database
[group('monitoring')]
@labels:
    uv run -- python pipelines/labels.py --environment=conda run

# Run the monitoring pipeline
[group('monitoring')]
@monitor:
    uv run -- python pipelines/monitoring.py --environment=conda run

# Run monitoring pipeline card server 
[group('monitoring')]
@monitor-viewer:
    uv run -- python pipelines/monitoring.py --environment=conda card server --port 8334




# Deploy model to SageMaker
deploy-sagemaker endpoint:
    mlflow sagemaker build-and-push-container
    python3 pipelines/deployment.py --environment=pypi run --target sagemaker --endpoint {{endpoint}} --region $AWS_REGION --data-capture-destination-uri s3://$BUCKET/datastore

# Deploy model to Azure
deploy-azure endpoint:
    python3 pipelines/deployment.py --environment=pypi run --target azure --endpoint {{endpoint}}

# Clean up AWS resources
cleanup-aws:
    aws cloudformation delete-stack --stack-name mlflow
    aws cloudformation delete-stack --stack-name metaflow
    aws cloudformation delete-stack --stack-name mlschool
    aws sagemaker delete-endpoint --endpoint-name $ENDPOINT_NAME

# Clean up Azure resources  
cleanup-azure:
    az ml online-endpoint delete --name $ENDPOINT_NAME --resource-group $AZURE_RESOURCE_GROUP --workspace-name $AZURE_WORKSPACE --no-wait --yes
    az group delete --name $AZURE_RESOURCE_GROUP
