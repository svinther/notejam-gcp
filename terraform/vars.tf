terraform {
  backend "gcs" {
    prefix = "terraform/state"
  }

  required_providers {
    hashicorp = {
      source = "hashicorp/random"
      version = "~> 2.3.0"
    }
  }
}

variable "githubowner" {}

variable "githubrepo" {}

variable "gcp_region" {}

variable "project_code" {}

//variable "gcp_credentials_file" {}

variable "gcp_project" {}

variable "pipeline_stages" {
  default = [
    "testing",
    "production"
  ]
}

variable "development_pipeline_stage" {
  default = "development"
}

locals {
  all_pipeline_stages = toset(concat([
    var.development_pipeline_stage], var.pipeline_stages))
}

provider "google" {
  project = var.gcp_project
  region = var.gcp_region
  //https://github.com/terraform-providers/terraform-provider-google/blob/master/CHANGELOG.md
  version = "3.41.0"
}

//beta is for cloud-build
provider "google-beta" {
  project = var.gcp_project
  region = var.gcp_region
  //https://github.com/terraform-providers/terraform-provider-google-beta/blob/master/CHANGELOG.md
  version = "3.41.0"
}


data "google_client_config" "default" {}

data "google_compute_network" "default" {
  name = "default"
}

data "google_project" "project" {
}

