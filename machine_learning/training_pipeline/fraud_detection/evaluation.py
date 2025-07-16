import matplotlib.pyplot as plt
import wandb
import os 
import io
import shutil
from sklearn.metrics import (
    classification_report,
    confusion_matrix,
    roc_auc_score,
    precision_recall_curve,
    auc,
    ConfusionMatrixDisplay,
)
from config import CONFUSION_MATRIX_PATH, ARTIFACTS_DIR 
from utils import is_gcs_path, open_file 


def evaluate_model(pipeline, X_test, y_test):
    """Evaluates the model and saves the confusion matrix."""
    y_pred = pipeline.predict(X_test)
    y_pred_proba = pipeline.predict_proba(X_test)[:, 1]

    print(" >> Model Evaluation Report ....")
    print(
        classification_report(y_test, y_pred, target_names=["Not Flagged", "Flagged"])
    )

    roc_auc = roc_auc_score(y_test, y_pred_proba)
    precision, recall, _ = precision_recall_curve(y_test, y_pred_proba)
    pr_auc = auc(recall, precision)
    print(f"ROC AUC Score: {roc_auc:.4f}")
    print(f"Precision-Recall AUC Score: {pr_auc:.4f}")

    # Log metrics to W&B
    report_dict = classification_report(y_test, y_pred, target_names=["Not Flagged", "Flagged"], output_dict=True)
    wandb.log({
        "eval_roc_auc": roc_auc,
        "eval_pr_auc": pr_auc,
        "eval_precision_flagged": report_dict["Flagged"]["precision"],
        "eval_recall_flagged": report_dict["Flagged"]["recall"],
        "eval_f1_score_flagged": report_dict["Flagged"]["f1-score"],
        "eval_precision_not_flagged": report_dict["Not Flagged"]["precision"],
        "eval_recall_not_flagged": report_dict["Not Flagged"]["recall"],
        "eval_f1_score_not_flagged": report_dict["Not Flagged"]["f1-score"],
        "eval_accuracy": report_dict["accuracy"]
    })

    cm = confusion_matrix(y_test, y_pred)
    disp = ConfusionMatrixDisplay(
        confusion_matrix=cm, display_labels=["Not Flagged", "Flagged"]
    )
    disp.plot(cmap=plt.cm.Blues)
    plt.title("Confusion Matrix on Test Set")

    # Define a temporary local path for the confusion matrix image
    # This local path will be used for W&B logging and then copied to the final destination if GCS.
    local_cm_path = os.path.join(ARTIFACTS_DIR if not is_gcs_path(ARTIFACTS_DIR) else ".", "confusion_matrix_local.png")
    if is_gcs_path(ARTIFACTS_DIR) and not os.path.exists(os.path.dirname(local_cm_path)):
        os.makedirs(os.path.dirname(local_cm_path), exist_ok=True) 

    plt.savefig(local_cm_path)
    print(f"Confusion matrix temporarily saved to {local_cm_path}")

    # Log the locally saved confusion matrix image to W&B
    wandb.log({"confusion_matrix": wandb.Image(local_cm_path)})

    # Ensure the image is at the final CONFUSION_MATRIX_PATH
    if local_cm_path != CONFUSION_MATRIX_PATH:
        if is_gcs_path(CONFUSION_MATRIX_PATH):
            print(f"Copying confusion matrix from {local_cm_path} to GCS path {CONFUSION_MATRIX_PATH}...")
            try:
                with open(local_cm_path, "rb") as local_f, open_file(CONFUSION_MATRIX_PATH, "wb") as dest_f:
                    shutil.copyfileobj(local_f, dest_f)
                print(f"Successfully copied confusion matrix to {CONFUSION_MATRIX_PATH}")
            except Exception as e:
                print(f"Error copying confusion matrix to GCS: {e}")
        else: 
            print(f"Copying confusion matrix from {local_cm_path} to local path {CONFUSION_MATRIX_PATH}...")
            try:
               
                if not os.path.exists(os.path.dirname(CONFUSION_MATRIX_PATH)):
                    os.makedirs(os.path.dirname(CONFUSION_MATRIX_PATH), exist_ok=True)
                shutil.copyfile(local_cm_path, CONFUSION_MATRIX_PATH)
                print(f"Successfully copied confusion matrix to {CONFUSION_MATRIX_PATH}")
            except Exception as e:
                print(f"Error copying confusion matrix to {CONFUSION_MATRIX_PATH}: {e}")

    
    if local_cm_path != CONFUSION_MATRIX_PATH or is_gcs_path(ARTIFACTS_DIR) :
        if os.path.exists(local_cm_path): 
            os.remove(local_cm_path)
            print(f"Removed temporary local confusion matrix: {local_cm_path}")
    
    plt.close()
