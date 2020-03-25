resource "google_container_cluster" "gke_cluster" {
  location = data.google_client_config.default.region
  name = var.project_code

  # Disable basic auth and client certificate access to the cluster
  master_auth {
    username = ""
    password = ""

    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Not possible to create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So create the smallest possible default
  # node pool and immediately delete it.
  # Recommended usage https://www.terraform.io/docs/providers/google/r/container_cluster.html
  remove_default_node_pool = true
  initial_node_count = 1

  // Access to master can be restricted like this
  //  master_authorized_networks_config {
  //    cidr_blocks {
  //      cidr_block = "x.x.x.x/x"
  //    }
  //  }

  // https://cloud.google.com/kubernetes-engine/docs/how-to/private-clusters
  // https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster#restrict_network_access_to_the_control_plane_and_nodes
  private_cluster_config {
    //Use public endpoint for master, so we won't have to deal with VPN access for now
    enable_private_endpoint = false
    //Keep the nodes private
    enable_private_nodes = true
    //https://www.terraform.io/docs/providers/google/r/container_cluster.html#master_ipv4_cidr_block
    master_ipv4_cidr_block = "172.16.28.0/28"
  }

  // making the cluster VPC-native instead of routes-based
  // this is required for private nodes
  // https://www.terraform.io/docs/providers/google/r/container_cluster.html#ip_allocation_policy
  ip_allocation_policy {
    //    cluster_secondary_range_name = google_compute_subnetwork.subnet.secondary_ip_range.0.range_name
    //    services_secondary_range_name = google_compute_subnetwork.subnet.secondary_ip_range.1.range_name
  }

  //Terraform should not obsess over seperatly managed nodepool, and k8s node autoscaling
  lifecycle {
    ignore_changes = [
      node_pool,
      initial_node_count
    ]
  }
}

//Service account for the nodes
//https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster#use_least_privilege_sa
resource "google_service_account" "gke_cluster-service_account" {
  account_id = var.project_code
}

resource "google_project_iam_member" "logging_logWriter" {
  role = "roles/logging.logWriter"
  member = "serviceAccount:${google_service_account.gke_cluster-service_account.email}"
}

resource "google_project_iam_member" "monitoring_metricWriter" {
  role = "roles/monitoring.metricWriter"
  member = "serviceAccount:${google_service_account.gke_cluster-service_account.email}"
}

resource "google_project_iam_member" "monitoring_viewer" {
  role = "roles/monitoring.viewer"
  member = "serviceAccount:${google_service_account.gke_cluster-service_account.email}"
}


resource "google_container_node_pool" "gke_cluster-nodepool01" {
  name = "${var.project_code}-nodepool"

  location = data.google_client_config.default.region
  cluster = google_container_cluster.gke_cluster.name

  initial_node_count = 1
  node_count = null

  node_config {
    preemptible = true
    machine_type = "g1-small"

    metadata = {
      disable-legacy-endpoints = "true"
    }

    # This is how to configure the access scopes, when managing everything by service account
    # https://cloud.google.com/compute/docs/access/service-accounts#associating_a_service_account_to_an_instance
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    service_account = google_service_account.gke_cluster-service_account.email
  }

  management {
    auto_repair = true
    auto_upgrade = true
  }

  //For a regional cluster, multiply by number of zones, e.g. 3 for region europe-west6
  autoscaling {
    max_node_count = 2
    min_node_count = 1
  }
}

//Explicitly configure kubernetes provider to the newly created cluster
//This enables creation of Kubernetes artifacts from Terraform (e.g Secrets)
provider kubernetes {
  version = "1.11.1"
  //  https://github.com/terraform-providers/terraform-provider-kubernetes/releases

  load_config_file = false
  host = "https://${google_container_cluster.gke_cluster.endpoint}"
  token = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.gke_cluster.master_auth.0.cluster_ca_certificate)
}

// Provision the namespaces to keep separate stage environments
resource "kubernetes_namespace" "namespace" {
  for_each = local.all_pipeline_stages

  metadata {
    name = each.key
  }
}
