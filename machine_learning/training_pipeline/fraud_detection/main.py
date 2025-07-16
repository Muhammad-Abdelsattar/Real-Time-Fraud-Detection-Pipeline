import os
import time
import wandb # Import W&B

# Local module imports
import config
from data_preparation import prepare_data
from training import run_hpo_and_train
from evaluation import evaluate_model
from model_exporter import export_model
from utils import ensure_path_exists

def run_pipeline():
    """Main function to orchestrate the ML pipeline."""

    # Initialize W&B Run
    wandb.init(
        project=config.WANDB_PROJECT,
        config={
            "data_path": config.DATA_PATH,
            "artifacts_dir": config.ARTIFACTS_DIR,
            "test_size_ratio": config.TEST_SIZE_RATIO,
            "n_trials_hpo": config.N_TRIALS,
            "target_column": config.TARGET,
            "export_type": config.EXPORT_TYPE,
            "study_name": config.STUDY_NAME,
            "cv_splits_hpo": config.N_SPLITS_CV
        }
    )

    start_time = time.time()

    # Ensure artifacts directory exists (handles local and GCS paths appropriately)
    ensure_path_exists(config.ARTIFACTS_DIR)

    print("--- Step 1/4: Preparing Data ---")
    X_train, X_test, y_train, y_test, features_dict = prepare_data()
    print("Data preparation complete.")

    print("\n--- Step 2/4: Running Hyperparameter Optimization and Training ---")
    final_pipeline = run_hpo_and_train(X_train, y_train, features_dict["num_cols"], features_dict["cat_cols"])
    print("Model training complete.")

    print("\n--- Step 3/4: Evaluating Final Model ---")
    evaluate_model(final_pipeline, X_test, y_test)
    print("Evaluation complete.")

    print("\n--- Step 4/4: Exporting Model for Inference ---")
    X_sample = X_train.head(1)
    export_model(final_pipeline, X_sample, export_type=config.EXPORT_TYPE)
    
    end_time = time.time()
    pipeline_duration = end_time - start_time
    print(f"\nPipeline finished successfully in {pipeline_duration:.2f} seconds.")
    wandb.log({"pipeline_duration_seconds": pipeline_duration})
    
    wandb.finish()

if __name__ == "__main__":
    try:
        run_pipeline()
    except Exception as e:
        print(f"Pipeline failed with error: {e}")
        if wandb.run is not None: # Ensure wandb was initialized
            wandb.log({"pipeline_error": str(e)})
            wandb.finish(exit_code=1) # Mark run as failed
        raise 
