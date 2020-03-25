
# Internet access is required for services like Image Registry

resource "google_compute_router" "internet" {
  name = "internet"
  network = data.google_compute_network.default.name
}

resource "google_compute_address" "internet" {
  name = "internet"
}

resource "google_compute_router_nat" "internet" {
  name = "internet"
  router = google_compute_router.internet.name

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips = google_compute_address.internet[*].self_link
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }

}
