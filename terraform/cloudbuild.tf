// Allow Cloud build to access GKE
// https://cloud.google.com/cloud-build/docs/securing-builds/set-service-account-permissions
resource "google_project_iam_member" "cloudbuild_container_developer" {
  role = "roles/container.developer"
  member = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

// Build docker image, push it to image registry, trigger deploy by adding a tag to git repo
// https://cloud.google.com/cloud-build/docs/configuring-builds/substitute-variable-values
resource "google_cloudbuild_trigger" "buildtrigger" {
  provider = google-beta
  name = "buildtrigger"

  build {
    // Pull will fail if we never build the branch before,
    // and cloud build steps can not be allowed to fail without putting the build on halt,
    // so we invoke docker from a bash shell, and make sure to always exit with zero exit code.
    step {
      name = "gcr.io/cloud-builders/docker"
      id = "docker pull for cache"
      entrypoint = "bash"
      args = [
        "-c",
        "docker pull $_IMAGE_NAME:$BRANCH_NAME || true"
      ]

      env = []
      secret_env = []
      wait_for = []
    }

    //Build the docker image
    //Use the just pulled same branch image as build cache
    step {
      name = "gcr.io/cloud-builders/docker"
      dir = "flask"
      id = "docker build"
      args = [
        "build",
        "--cache-from",
        "$_IMAGE_NAME:$BRANCH_NAME",
        "-t",
        "$_IMAGE_NAME:$COMMIT_SHA",
        "-t",
        "$_IMAGE_NAME:$BRANCH_NAME",
        "-f",
        "Dockerfile",
        ".",
      ]
    }

    //Perform testing
    step {
      name = "gcr.io/cloud-builders/docker"
      id = "test"
      args = [
        "run",
        "--rm",
        "$_IMAGE_NAME:$BRANCH_NAME",
        "python",
        "tests.py"
      ]
    }

    // Push manually to ensure image is available before deploy stem
    step {
      name = "gcr.io/cloud-builders/docker"
      id = "docker push COMMIT_SHA tag"
      args = [
        "push",
        "$_IMAGE_NAME:$COMMIT_SHA"
      ]
    }

    // Push manually to ensure image is available before deploy step
    step {
      name = "gcr.io/cloud-builders/docker"
      id = "docker push BRANCH_NAME tag"
      args = [
        "push",
        "$_IMAGE_NAME:$BRANCH_NAME"
      ]
    }

    step {
      id = "Substitute k8s manifest files"
      name = "debian:10.3-slim"
      args = [
        "bash",
        "-c",
        "sed -i -e 's%@IMAGE_NAME@%$_IMAGE_NAME%g' ./flask/k8s/*.yaml"
      ]
    }

    // Deploy immediately to GKE
    step {
      name = "gcr.io/cloud-builders/gke-deploy"
      dir = "flask"
      id = "k8s deploy"
      args = [
        "run",
        "--filename=$_K8S_YAML_PATH",
        // deploy the just build development image
        "--image=$_IMAGE_NAME:$BRANCH_NAME",
        "--app=$_APP_NAME",
        "--version=$BRANCH_NAME",
        // deploy to this stage (namespace)
        "--namespace=$BRANCH_NAME",
        "--annotation=gcb-build-id=$BUILD_ID",
        "--cluster=$_GKE_CLUSTER",
        "--location=$_GKE_LOCATION"
      ]
    }
  }


  github {
    owner = var.githubowner
    name = var.githubrepo
    push {
      //Only build images for the development stage, other stages get the same images deployed when the images
      //are promoted through git tags, e.g
      branch = var.development_pipeline_stage
    }
  }

  substitutions = {
    _IMAGE_NAME = "eu.${data.google_container_registry_repository.default.repository_url}/${var.project_code}"
    _GKE_CLUSTER = google_container_cluster.gke_cluster.name
    _GKE_LOCATION = google_container_cluster.gke_cluster.location
    _K8S_YAML_PATH = "k8s"
    _APP_NAME = var.project_code
  }
}

// This trigger is triggered when tagging the app git repo with a tag with the pipeline stage name
// e.g one of development | testing | production
// the image tagged with the corresponsing commit hash is deployed to the pipeline stage
resource "google_cloudbuild_trigger" "deploytrigger" {
  provider = google-beta
  name = "deploytrigger"

  build {
    step {
      id = "Substitute k8s manifest files"
      name = "debian:10.3-slim"
      args = [
        "bash",
        "-c",
        "sed -i -e 's%@IMAGE_NAME@%$_IMAGE_NAME%g' ./flask/k8s/*.yaml"
      ]
    }

    // Deploy to GKE
    step {
      name = "gcr.io/cloud-builders/gke-deploy"
      dir = "flask"
      id = "k8s deploy"
      args = [
        "run",
        "--filename=$_K8S_YAML_PATH",
        // deploy this image, corresponding to the build of tagged commit
        "--image=$_IMAGE_NAME:$COMMIT_SHA",
        "--app=$_APP_NAME",
        "--version=$TAG_NAME",
        // deploy to this stage (namespace)
        "--namespace=$TAG_NAME",
        "--annotation=gcb-build-id=$BUILD_ID",
        "--cluster=$_GKE_CLUSTER",
        "--location=$_GKE_LOCATION"
      ]
    }
  }

  github {
    owner = var.githubowner
    name = var.githubrepo
    push {
      //Construct a RE that corresponds to any of the pipeline stages (deploy on any stage)
      tag = join("|", formatlist("(?:%s)", var.pipeline_stages))
    }
  }

  substitutions = {
    _IMAGE_NAME = "eu.${data.google_container_registry_repository.default.repository_url}/${var.project_code}"
    _GKE_CLUSTER = google_container_cluster.gke_cluster.name
    _GKE_LOCATION = google_container_cluster.gke_cluster.location
    _K8S_YAML_PATH = "k8s"
    _APP_NAME = var.project_code
  }
}


