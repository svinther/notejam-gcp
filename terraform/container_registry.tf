
# Initialize registry, this will create the storage bucket
resource "google_container_registry" "default" {
  project  = data.google_client_config.default.project
  location = "EU"
}

data "google_container_registry_repository" "default" {
}

# Allow access to the storage bucket for the Service Account used on GKE nodes
resource "google_storage_bucket_iam_member" "viewer" {
  bucket = google_container_registry.default.id
  role = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.gke_cluster-service_account.email}"
}