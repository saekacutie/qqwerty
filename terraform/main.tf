locals {
  prefix           = substr(replace(var.service_name, "_", "-"), 0, 24)
  enable_tcp_proxy = var.enable_tcp_proxy && length(var.tcp_source_ranges) > 0
  common_labels = {
    application = "xgcpx"
    managed_by  = "terraform"
  }
  blocked_cidr_expression = join(" || ", [for cidr in var.blocked_cidrs : "inIpRange(origin.ip, '${cidr}')"])
  allowed_cidr_expression = join(" || ", [for cidr in var.allowed_cidrs : "inIpRange(origin.ip, '${cidr}')"])
}

resource "google_project_service" "required" {
  for_each = toset([
    "compute.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_cloud_run_v2_service" "gateway" {
  name                = var.service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  deletion_protection = true
  labels              = local.common_labels

  template {
    timeout = "3600s"
    scaling {
      min_instance_count = 0
      max_instance_count = 100
    }
    containers {
      image = var.image
      ports {
        name           = "h2c"
        container_port = 8080
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }
      env {
        name  = "UPSTREAM_PRIMARY"
        value = var.upstream_primary
      }
      env {
        name  = "UPSTREAM_FALLBACK"
        value = var.upstream_fallback
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_service_iam_member" "load_balancer_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.gateway.location
  name     = google_cloud_run_v2_service.gateway.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_network" "gateway" {
  name                    = "${local.prefix}-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "gateway" {
  name                     = "${local.prefix}-subnet"
  region                   = var.region
  network                  = google_compute_network.gateway.id
  ip_cidr_range            = "10.40.0.0/20"
  private_ip_google_access = true
}

resource "google_service_account" "gateway_vm" {
  account_id   = "${local.prefix}-vm"
  display_name = "xgcpx persistent gateway VM"
}

resource "google_project_iam_member" "vm_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gateway_vm.email}"
}

resource "google_project_iam_member" "vm_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gateway_vm.email}"
}

resource "google_compute_instance_template" "gateway" {
  name_prefix  = "${local.prefix}-vm-"
  machine_type = var.machine_type
  tags         = ["${local.prefix}-gateway"]
  labels       = local.common_labels

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
    disk_type    = "pd-balanced"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.gateway.id
    access_config {}
  }

  service_account {
    email  = google_service_account.gateway_vm.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    gce-container-declaration = templatefile("${path.module}/container-declaration.yaml.tftpl", {
      image             = var.image
      upstream_primary  = var.upstream_primary
      upstream_fallback = var.upstream_fallback
      tcp_upstream_host = var.tcp_upstream_host
      tls_upstream_host = var.tls_upstream_host
    })
  }

  lifecycle {
    create_before_destroy = true
  }
  depends_on = [google_project_iam_member.vm_artifact_reader]
}

data "google_compute_zones" "protocol_vm" {
  project = var.project_id
  region  = var.region
  status  = "UP"
}

resource "google_service_account" "protocol_vm" {
  count        = var.enable_protocol_gateway ? 1 : 0
  account_id   = substr("${local.prefix}-proto", 0, 30)
  display_name = "xgcpx authenticated protocol VM"
}

resource "google_project_iam_member" "protocol_vm_artifact_reader" {
  count   = var.enable_protocol_gateway ? 1 : 0
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.protocol_vm[0].email}"
}

resource "google_secret_manager_secret_iam_member" "protocol_config_reader" {
  count     = var.enable_protocol_gateway ? 1 : 0
  project   = var.project_id
  secret_id = var.protocol_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.protocol_vm[0].email}"
}

resource "google_secret_manager_secret_iam_member" "openvpn_config_reader" {
  count     = var.enable_protocol_gateway && var.enable_openvpn ? 1 : 0
  project   = var.project_id
  secret_id = var.openvpn_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.protocol_vm[0].email}"
}

resource "google_compute_address" "protocol_vm" {
  count        = var.enable_protocol_gateway ? 1 : 0
  name         = "${local.prefix}-protocol-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "terraform_data" "protocol_deployment" {
  input = {
    image                  = var.protocol_image_revision
    secret_version         = var.protocol_secret_version
    openvpn_image          = var.openvpn_image
    openvpn_secret_version = var.openvpn_secret_version
  }

  triggers_replace = {
    image                  = var.protocol_image_revision
    secret_version         = var.protocol_secret_version
    openvpn_image          = var.openvpn_image
    openvpn_secret_version = var.openvpn_secret_version
  }
}

resource "google_compute_instance" "protocol_vm" {
  count        = var.enable_protocol_gateway ? 1 : 0
  name         = "${local.prefix}-protocol-vm"
  zone         = try(sort(data.google_compute_zones.protocol_vm.names)[0], "")
  machine_type = var.machine_type
  tags         = ["${local.prefix}-protocol"]
  labels       = local.common_labels

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.gateway.id
    access_config {
      nat_ip = google_compute_address.protocol_vm[0].address
    }
  }

  service_account {
    email  = google_service_account.protocol_vm[0].email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    startup-script = var.protocol_startup_script
  }

  depends_on = [
    google_project_iam_member.protocol_vm_artifact_reader,
    google_secret_manager_secret_iam_member.protocol_config_reader,
    google_secret_manager_secret_iam_member.openvpn_config_reader,
  ]

  lifecycle {
    replace_triggered_by = [terraform_data.protocol_deployment]

    precondition {
      condition     = var.protocol_image != "" && var.protocol_domain != "" && var.protocol_secret_name != "" && var.protocol_startup_script != "" && var.protocol_secret_version != "" && var.protocol_image_revision != ""
      error_message = "The protocol VM requires an image, relay hostname, Secret Manager version, and rendered startup script from deploy.sh."
    }

    precondition {
      condition     = contains(var.protocol_tcp_ports, "80") && contains(var.protocol_tcp_ports, "443")
      error_message = "The protocol VM must expose TCP 80 and 443 for HTTP redirects and TLS."
    }

    precondition {
      condition     = !var.enable_openvpn || (var.openvpn_image != "" && var.openvpn_secret_name != "" && var.openvpn_secret_version != "" && contains(var.protocol_udp_ports, "1194"))
      error_message = "OpenVPN requires its image, Secret Manager secret/version, and UDP port 1194."
    }

    precondition {
      condition     = length(data.google_compute_zones.protocol_vm.names) > 0
      error_message = "No active Compute Engine zone was found in the selected region."
    }
  }
}

resource "google_compute_firewall" "protocol_public" {
  count         = var.enable_protocol_gateway ? 1 : 0
  name          = "${local.prefix}-protocol-public"
  network       = google_compute_network.gateway.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${local.prefix}-protocol"]

  dynamic "allow" {
    for_each = length(var.protocol_tcp_ports) > 0 ? [1] : []
    content {
      protocol = "tcp"
      ports    = var.protocol_tcp_ports
    }
  }

  dynamic "allow" {
    for_each = length(var.protocol_udp_ports) > 0 ? [1] : []
    content {
      protocol = "udp"
      ports    = var.protocol_udp_ports
    }
  }
}

resource "google_compute_region_instance_group_manager" "gateway" {
  name               = "${local.prefix}-mig"
  region             = var.region
  base_instance_name = "${local.prefix}-vm"
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.gateway.id
  }

  named_port {
    name = "http"
    port = 8080
  }
  named_port {
    name = "tcp"
    port = 9000
  }
  named_port {
    name = "tls"
    port = 9443
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.vm.id
    initial_delay_sec = 180
  }

  lifecycle {
    ignore_changes = [target_size]
  }
}

resource "google_compute_region_autoscaler" "gateway" {
  name   = "${local.prefix}-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.gateway.id

  autoscaling_policy {
    min_replicas    = 1
    max_replicas    = 3
    cooldown_period = 120
    cpu_utilization {
      target = 0.65
    }
  }
}

resource "google_compute_firewall" "lb_to_vm" {
  name          = "${local.prefix}-allow-lb-health-checks"
  network       = google_compute_network.gateway.name
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${local.prefix}-gateway"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_compute_firewall" "tcp_proxy" {
  count         = local.enable_tcp_proxy ? 1 : 0
  name          = "${local.prefix}-allow-tcp-proxy"
  network       = google_compute_network.gateway.name
  direction     = "INGRESS"
  source_ranges = var.tcp_source_ranges
  target_tags   = ["${local.prefix}-gateway"]

  allow {
    protocol = "tcp"
    ports    = ["9000", "9443"]
  }
}

resource "google_compute_firewall" "tcp_health_checks" {
  count         = local.enable_tcp_proxy ? 1 : 0
  name          = "${local.prefix}-allow-tcp-health-checks"
  network       = google_compute_network.gateway.name
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${local.prefix}-gateway"]

  allow {
    protocol = "tcp"
    ports    = ["9000", "9443"]
  }
}

resource "google_compute_health_check" "vm" {
  name                = "${local.prefix}-vm-hc"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_region_health_check" "tcp_proxy" {
  count               = local.enable_tcp_proxy ? 1 : 0
  name                = "${local.prefix}-tcp-hc"
  region              = var.region
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
  tcp_health_check { port = 9000 }
}

resource "google_compute_region_health_check" "tls_proxy" {
  count               = local.enable_tcp_proxy ? 1 : 0
  name                = "${local.prefix}-tls-hc"
  region              = var.region
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
  tcp_health_check { port = 9443 }
}

resource "google_compute_address" "tcp_proxy" {
  count        = local.enable_tcp_proxy ? 1 : 0
  name         = "${local.prefix}-tcp-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_address" "tls_proxy" {
  count        = local.enable_tcp_proxy ? 1 : 0
  name         = "${local.prefix}-tls-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_region_backend_service" "tcp_proxy" {
  count                 = local.enable_tcp_proxy ? 1 : 0
  name                  = "${local.prefix}-tcp-backend"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_region_health_check.tcp_proxy[0].id]
  port_name             = "tcp"
  backend {
    group          = google_compute_region_instance_group_manager.gateway.instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_region_backend_service" "tls_proxy" {
  count                 = local.enable_tcp_proxy ? 1 : 0
  name                  = "${local.prefix}-tls-backend"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_region_health_check.tls_proxy[0].id]
  port_name             = "tls"
  backend {
    group          = google_compute_region_instance_group_manager.gateway.instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "tcp_proxy" {
  count                 = local.enable_tcp_proxy ? 1 : 0
  name                  = "${local.prefix}-tcp-forwarding"
  region                = var.region
  ip_address            = google_compute_address.tcp_proxy[0].address
  backend_service       = google_compute_region_backend_service.tcp_proxy[0].id
  ip_protocol           = "TCP"
  ports                 = ["9000"]
  load_balancing_scheme = "EXTERNAL"
  network_tier          = "PREMIUM"
}

resource "google_compute_forwarding_rule" "tls_proxy" {
  count                 = local.enable_tcp_proxy ? 1 : 0
  name                  = "${local.prefix}-tls-forwarding"
  region                = var.region
  ip_address            = google_compute_address.tls_proxy[0].address
  backend_service       = google_compute_region_backend_service.tls_proxy[0].id
  ip_protocol           = "TCP"
  ports                 = ["9443"]
  load_balancing_scheme = "EXTERNAL"
  network_tier          = "PREMIUM"
}

resource "google_compute_security_policy" "edge" {
  name        = "${local.prefix}-edge-policy"
  description = "xgcpx WAF, source filtering, and per-client rate controls"
  type        = "CLOUD_ARMOR"

  dynamic "rule" {
    for_each = length(var.blocked_cidrs) > 0 ? [1] : []
    content {
      action   = "deny(403)"
      priority = 100
      match {
        expr { expression = local.blocked_cidr_expression }
      }
      description = "Deny configured source CIDRs"
    }
  }

  rule {
    action   = "deny(403)"
    priority = 200
    match {
      expr { expression = "evaluatePreconfiguredWaf('sqli-v33-stable') || evaluatePreconfiguredWaf('xss-v33-stable')" }
    }
    description = "Block common SQL injection and XSS signatures"
  }

  rule {
    action   = "rate_based_ban"
    priority = 300
    match {
      expr { expression = "true" }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.requests_per_minute
        interval_sec = 60
      }
      ban_duration_sec = 300
      ban_threshold {
        count        = var.requests_per_minute * 2
        interval_sec = 60
      }
    }
    description = "Per-client rate limit and temporary ban"
  }

  dynamic "rule" {
    for_each = length(var.allowed_cidrs) > 0 ? [1] : []
    content {
      action   = "allow"
      priority = 900
      match {
        expr { expression = local.allowed_cidr_expression }
      }
      description = "Allow configured source CIDRs"
    }
  }

  rule {
    action   = length(var.allowed_cidrs) > 0 ? "deny(403)" : "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    description = "Default deny when source allowlist is configured, otherwise allow"
  }
}

resource "google_compute_global_address" "edge" {
  name = "${local.prefix}-global-ip"
}

resource "google_compute_managed_ssl_certificate" "edge" {
  name = "${local.prefix}-managed-cert"
  managed {
    domains = [var.domain]
  }
}

resource "google_compute_region_network_endpoint_group" "cloud_run" {
  name                  = "${local.prefix}-run-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run { service = google_cloud_run_v2_service.gateway.name }
}

resource "google_compute_backend_service" "cloud_run" {
  name                  = "${local.prefix}-run-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  # Match Cloud Run's 3600-second request limit so long-lived HTTP streams are not cut short at the edge.
  timeout_sec     = 3600
  enable_cdn      = true
  security_policy = google_compute_security_policy.edge.id
  backend { group = google_compute_region_network_endpoint_group.cloud_run.id }
}

resource "google_compute_backend_service" "vm" {
  name                  = "${local.prefix}-vm-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 3600
  security_policy       = google_compute_security_policy.edge.id
  health_checks         = [google_compute_health_check.vm.id]
  backend {
    group           = google_compute_region_instance_group_manager.gateway.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
  }
}

resource "google_compute_url_map" "https" {
  name            = "${local.prefix}-https-map"
  default_service = google_compute_backend_service.cloud_run.id

  host_rule {
    hosts        = [var.domain]
    path_matcher = "gateway-routes"
  }
  path_matcher {
    name            = "gateway-routes"
    default_service = google_compute_backend_service.cloud_run.id
    path_rule {
      paths   = ["/persistent/*"]
      service = google_compute_backend_service.vm.id
    }
  }
}

resource "google_compute_target_https_proxy" "https" {
  name             = "${local.prefix}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.edge.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${local.prefix}-https-forwarding"
  ip_address            = google_compute_global_address.edge.address
  target                = google_compute_target_https_proxy.https.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_url_map" "http_redirect" {
  name = "${local.prefix}-http-redirect"
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_http_proxy" "http_redirect" {
  name    = "${local.prefix}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  name                  = "${local.prefix}-http-forwarding"
  ip_address            = google_compute_global_address.edge.address
  target                = google_compute_target_http_proxy.http_redirect.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}