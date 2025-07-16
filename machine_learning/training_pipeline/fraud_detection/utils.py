import os
import gcsfs


def is_gcs_path(path: str) -> bool:
    """Checks if a path string starts with gs://."""
    return path.startswith("gs://")

def ensure_path_exists(path: str):
    """
    Ensures that the directory for the given path exists if it's a local path.
    If it's a GCS path, does nothing as GCS directories are implicit.
    Ensures that the given directory path exists if it's a local path.
    If it's a GCS path, does nothing as GCS directories are implicit.
    """
    if not is_gcs_path(path):
        if path: # Ensure path is not empty
            os.makedirs(path, exist_ok=True)
            print(f"Ensured local directory exists: {path}")
        else:
            print(f"Path is empty. No directory created by ensure_path_exists.")
    else:
        print(f"Path '{path}' is a GCS path. Directory creation is implicit on GCS.")

def open_file(path: str, mode: str, gcs_project: str = None):
    """
    Opens a file, supporting both local and GCS paths.
    For GCS, uses gcsfs.
    'gcs_project' can be specified if the GCS path requires a specific project context
    that isn't covered by default credentials.
    """
    if is_gcs_path(path):
        fs = gcsfs.GCSFileSystem()
        return fs.open(path, mode)
    else:
        # Ensure parent directory exists for local file writing
        if 'w' in mode or 'a' in mode:
            parent_dir = os.path.dirname(path)
            if parent_dir and not os.path.exists(parent_dir):
                os.makedirs(parent_dir, exist_ok=True)
        return open(path, mode)
