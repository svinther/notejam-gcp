# Configure with Private IP, meaning no traffic between app and database will go to the Internet
# Seems sane, and it also promises reduced latency
# https://cloud.google.com/sql/docs/mysql/configure-private-ip

# Use global addresses, so migration to other regions will require less app reconfguration
resource "google_compute_global_address" "private_ip_address" {
  name = "private-ip-address"
  purpose = "VPC_PEERING"
  address_type = "INTERNAL"
  prefix_length = 24
  network = data.google_compute_network.default.self_link
}

# VPC Virtual Private Cloud
resource "google_service_networking_connection" "private_vpc_connection" {
  network = data.google_compute_network.default.self_link
  service = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [
    google_compute_global_address.private_ip_address.name]
}


resource "google_sql_database_instance" "dbserver" {
  name = var.project_code
  database_version = "POSTGRES_11"
  region = data.google_client_config.default.region

  depends_on = [
    google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "db-f1-micro"

    //Customer requires High Availability
    availability_type = "REGIONAL"

    ip_configuration {
      ipv4_enabled = false
      private_network = data.google_compute_network.default.self_link
    }
  }
}



resource "google_sql_database" "db" {
  for_each = local.all_pipeline_stages

  name = each.key
  instance = google_sql_database_instance.dbserver.name
}


resource "random_password" "dbpw" {
  for_each = local.all_pipeline_stages

  length = 10
  special = false
}

resource "google_sql_user" "dbuser" {
  for_each = local.all_pipeline_stages

  name = each.key
  instance = google_sql_database_instance.dbserver.name
  password = random_password.dbpw[each.key].result
}


resource "kubernetes_secret" "secret" {
  for_each = local.all_pipeline_stages

  metadata {
    name = "${var.project_code}-dbcreds"
    //This will ensure correct dependecy (namespaces exists)
    namespace = kubernetes_namespace.namespace[each.key].metadata.0.name
  }

  //By constructing the URI for the database with terraform, it will be trivial to get this URI into the app as an env var
  data = {
    username = google_sql_user.dbuser[each.key].name
    password = google_sql_user.dbuser[each.key].password
    dbhost = google_sql_database_instance.dbserver.first_ip_address
    dbname = google_sql_database.db[each.key].name
    database_uri = "postgresql://${google_sql_user.dbuser[each.key].name}:${google_sql_user.dbuser[each.key].password}@${google_sql_database_instance.dbserver.first_ip_address}/${google_sql_database.db[each.key].name}"
  }

  type = "Opaque"
}