locals {
  prefix          = substr(replace(var.service_name, "_", "-"), 0, 24)
  sa_prefix       = trim(substr(local.prefix, 0, 20), "-")
  builtin_backend = "http://127.0.0.1:8081"

  # Xray on the protocol VM (hybrid runtime). The VM's own hostname is <ip>.sslip.io unless one is supplied,
  # so the Cloud Run gateway can always route protocol traffic to it (this was empty before => traffic hit the built-in API).
  protocol_on_vm  = var.protocol_runtime == "vm" && var.enable_protocol_gateway
  protocol_vm_ip  = try(google_compute_address.protocol_vm[0].address, "")
  protocol_domain = var.protocol_domain != "" ? var.protocol_domain : (local.protocol_on_vm ? "${replace(local.protocol_vm_ip, ".", "-")}.sslip.io" : "")
  protocol_via_vm = !var.enable_cloudrun_protocols && (var.protocol_domain != "" || local.protocol_on_vm)

  protocol_upstream_scheme = var.enable_cloudrun_protocols ? "http" : (local.protocol_via_vm ? "https" : "http")
  protocol_upstream_host   = var.enable_cloudrun_protocols ? "127.0.0.1" : (local.protocol_via_vm ? local.protocol_domain : "127.0.0.1")
  protocol_upstream_port   = var.enable_cloudrun_protocols ? 8082 : (local.protocol_via_vm ? 443 : 8081)
  protocol_upstream        = "${local.protocol_upstream_scheme}://${local.protocol_upstream_host}:${local.protocol_upstream_port}"
  protocol_grpc_scheme     = var.enable_cloudrun_protocols ? "grpc" : (local.protocol_via_vm ? "grpcs" : "grpc")

  vm_protocol_upstream        = var.protocol_runtime == "cloud-run" ? local.builtin_backend : local.protocol_upstream
  vm_protocol_upstream_host   = var.protocol_runtime == "cloud-run" ? "127.0.0.1" : local.protocol_upstream_host
  vm_protocol_upstream_port   = var.protocol_runtime == "cloud-run" ? 8081 : local.protocol_upstream_port
  vm_protocol_upstream_scheme = var.protocol_runtime == "cloud-run" ? "http" : local.protocol_upstream_scheme
  vm_protocol_grpc_scheme     = var.protocol_runtime == "cloud-run" ? "grpc" : local.protocol_grpc_scheme

  vm_boot_disk_type = var.machine_type == "e2-micro" ? "pd-standard" : "pd-balanced"
  vm_boot_disk_size = var.machine_type == "e2-micro" ? 15 : 20
  enable_tcp_proxy  = var.enable_tcp_proxy && length(var.tcp_source_ranges) > 0
  use_lb            = !var.use_cloud_run_host
  create_gateway_vm = local.use_lb || local.enable_tcp_proxy

  # Google front ends and health checkers that must reach the gateway VM.
  google_lb_ranges = ["130.211.0.0/22", "35.191.0.0/16", "34.96.0.0/20", "34.127.192.0/18"]

  common_labels = {
    application = "xgcpx"
    managed_by  = "terraform"
  }

  # Cloud Armor rules allow at most 10 ranges each, so CIDR lists are split into chunks.
  blocked_chunks = chunklist(var.blocked_cidrs, 10)
  # The rate limiter is scoped to the allowlist when there is one, so a conforming request from a
  # non-allowlisted client can never short-circuit past the default-deny rule.
  rate_limit_scopes = length(var.allowed_cidrs) > 0 ? chunklist(var.allowed_cidrs, 10) : [["*"]]
}

resource "google_project_service" "required" {
  for_each = toset([
    "serviceusage.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbilling.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_cloud_run_v2_service" "gateway" {
  name                = var.service_name
  location            = var.region
  ingress             = local.use_lb ? "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" : "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.deletion_protection
  labels              = local.common_labels

  lifecycle {
    precondition {
      condition     = var.use_cloud_run_host || var.domain != ""
      error_message = "domain is required unless use_cloud_run_host is true."
    }

    precondition {
      condition = startswith(var.upstream_primary, "https://") == startswith(var.upstream_fallback, "https://") && (
        !startswith(var.upstream_primary, "https://") ||
        split("/", trimprefix(var.upstream_primary, "https://"))[0] == split("/", trimprefix(var.upstream_fallback, "https://"))[0]
      )
      error_message = "upstream_primary and upstream_fallback must use the same scheme, and the same host when they use https."
    }

    precondition {
      condition     = var.backend_image != ""
      error_message = "The Cloud Run gateway requires the built-in backend sidecar image."
    }

    precondition {
      condition     = !var.enable_cloudrun_protocols || (var.protocol_image != "" && var.protocol_secret_name != "" && var.protocol_secret_version != "")
      error_message = "Cloud Run protocol routing requires the protocol image and Secret Manager config/version."
    }
  }

  template {
    timeout         = "3600s"
    service_account = var.enable_cloudrun_protocols ? google_service_account.cloudrun_protocols[0].email : null
    scaling {
      min_instance_count = var.min_instance_count
      max_instance_count = 100
    }
    containers {
      name       = "gateway"
      image      = var.image
      depends_on = var.enable_cloudrun_protocols ? ["backend", "protocol"] : ["backend"]
      # h2c = end-to-end HTTP/2 (gRPC, xHTTP stream-up/stream-one); http1 = HTTP/1.1, which Cloud Run
      # requires for WebSocket and HTTPUpgrade. Every gateway image accepts both on port 8080.
      ports {
        name           = var.cloud_run_http2 ? "h2c" : "http1"
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
      env {
        name  = "PROTOCOL_UPSTREAM"
        value = local.protocol_upstream
      }
      env {
        name  = "PROTOCOL_UPSTREAM_HOST"
        value = local.protocol_upstream_host
      }
      env {
        name  = "PROTOCOL_UPSTREAM_PORT"
        value = tostring(local.protocol_upstream_port)
      }
      env {
        name  = "PROTOCOL_UPSTREAM_SCHEME"
        value = local.protocol_upstream_scheme
      }
      env {
        name  = "PROTOCOL_GRPC_SCHEME"
        value = local.protocol_grpc_scheme
      }
    }
    containers {
      name  = "backend"
      image = var.backend_image
      startup_probe {
        tcp_socket {
          port = 8081
        }
        period_seconds    = 1
        timeout_seconds   = 1
        failure_threshold = 30
      }
      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
      }
    }
    dynamic "containers" {
      for_each = var.enable_cloudrun_protocols ? [1] : []
      content {
        name  = "protocol"
        image = var.protocol_image
        env {
          name  = "PROJECT_ID"
          value = var.project_id
        }
        env {
          name  = "PROTOCOL_SECRET_NAME"
          value = var.protocol_secret_name
        }
        env {
          name  = "RELAY_DOMAIN"
          value = var.protocol_domain != "" ? var.protocol_domain : var.domain
        }
        env {
          name  = "PROTOCOL_HTTP_ONLY"
          value = "true"
        }
        env {
          name  = "PROTOCOL_SECRET_VERSION"
          value = var.protocol_secret_version
        }
        startup_probe {
          tcp_socket {
            port = 8082
          }
          period_seconds    = 1
          timeout_seconds   = 1
          failure_threshold = 120
        }
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.required,
    google_secret_manager_secret_iam_member.cloudrun_protocol_config_reader,
  ]
}

resource "google_service_account" "cloudrun_protocols" {
  depends_on = [google_project_service.required]
  count        = var.enable_cloudrun_protocols ? 1 : 0
  account_id   = "${local.sa_prefix}-run-proto"
  display_name = "xgcpx Cloud Run protocol sidecar"
}

resource "google_secret_manager_secret_iam_member" "cloudrun_protocol_config_reader" {
  count     = var.enable_cloudrun_protocols ? 1 : 0
  project   = var.project_id
  secret_id = var.protocol_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloudrun_protocols[0].email}"
}

resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = google_cloud_run_v2_service.gateway.location
  name     = google_cloud_run_v2_service.gateway.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_network" "gateway" {
  depends_on = [google_project_service.required]
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
  depends_on = [google_project_service.required]
  count        = local.create_gateway_vm ? 1 : 0
  account_id   = "${local.sa_prefix}-vm"
  display_name = "xgcpx persistent gateway VM"
}

resource "google_project_iam_member" "vm_artifact_reader" {
  count   = local.create_gateway_vm ? 1 : 0
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gateway_vm[0].email}"
}

resource "google_project_iam_member" "vm_log_writer" {
  count   = local.create_gateway_vm ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gateway_vm[0].email}"
}

resource "google_compute_instance_template" "gateway" {
  count        = local.create_gateway_vm ? 1 : 0
  name_prefix  = "${local.prefix}-vm-"
  machine_type = var.machine_type
  tags         = ["${local.prefix}-gateway"]
  labels       = local.common_labels

  disk {
    source_image = "cos-cloud/cos-stable"
    auto_delete  = true
    boot         = true
    disk_size_gb = local.vm_boot_disk_size
    disk_type    = local.vm_boot_disk_type
  }

  network_interface {
    subnetwork = google_compute_subnetwork.gateway.id
    access_config {}
  }

  service_account {
    email  = google_service_account.gateway_vm[0].email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    gce-container-declaration = templatefile("${path.module}/container-declaration.yaml.tftpl", {
      image                    = var.image
      upstream_primary         = var.upstream_primary
      upstream_fallback        = var.upstream_fallback
      protocol_upstream        = local.vm_protocol_upstream
      protocol_upstream_host   = local.vm_protocol_upstream_host
      protocol_upstream_port   = local.vm_protocol_upstream_port
      protocol_upstream_scheme = local.vm_protocol_upstream_scheme
      protocol_grpc_scheme     = local.vm_protocol_grpc_scheme
      tcp_upstream_host        = var.tcp_upstream_host
      tls_upstream_host        = var.tls_upstream_host
    })
  }

  lifecycle {
    create_before_destroy = true
  }
  depends_on = [google_project_iam_member.vm_artifact_reader]
}

data "google_compute_zones" "protocol_vm" {
  depends_on = [google_project_service.required]
  project = var.project_id
  region  = var.region
  status  = "UP"
}

resource "google_service_account" "protocol_vm" {
  depends_on = [google_project_service.required]
  count        = var.enable_protocol_gateway ? 1 : 0
  account_id   = "${local.sa_prefix}-proto"
  display_name = "xgcpx authenticated protocol VM"
}

resource "google_project_iam_member" "protocol_vm_artifact_reader" {
  count   = var.enable_protocol_gateway ? 1 : 0
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.protocol_vm[0].email}"
}

# Only created for a real Xray secret, so an OpenVPN-only deployment never references an empty secret name.
resource "google_secret_manager_secret_iam_member" "protocol_config_reader" {
  depends_on = [google_project_service.required]
  count     = var.enable_protocol_gateway && var.protocol_runtime == "vm" && var.protocol_secret_name != "" ? 1 : 0
  project   = var.project_id
  secret_id = var.protocol_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.protocol_vm[0].email}"
}

resource "google_secret_manager_secret_iam_member" "openvpn_config_reader" {
  depends_on = [google_project_service.required]
  count     = var.enable_protocol_gateway && var.enable_openvpn ? 1 : 0
  project   = var.project_id
  secret_id = var.openvpn_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.protocol_vm[0].email}"
}

resource "google_compute_address" "protocol_vm" {
  depends_on = [google_project_service.required]
  count        = var.enable_protocol_gateway ? 1 : 0
  name         = "${local.prefix}-protocol-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "terraform_data" "protocol_deployment" {
  input = {
    image                  = var.protocol_runtime == "vm" ? var.protocol_image_revision : ""
    secret_version         = var.protocol_runtime == "vm" ? var.protocol_secret_version : ""
    openvpn_image          = var.openvpn_image
    openvpn_secret_version = var.openvpn_secret_version
  }

  triggers_replace = {
    image                  = var.protocol_runtime == "vm" ? var.protocol_image_revision : ""
    secret_version         = var.protocol_runtime == "vm" ? var.protocol_secret_version : ""
    openvpn_image          = var.openvpn_image
    openvpn_secret_version = var.openvpn_secret_version
  }
}

resource "google_compute_instance" "protocol_vm" {
  count        = var.enable_protocol_gateway ? 1 : 0
  name         = "${local.prefix}-protocol-vm"
  zone         = var.protocol_zone != "" ? var.protocol_zone : try(sort(data.google_compute_zones.protocol_vm.names)[0], "")
  machine_type = var.machine_type
  tags         = ["${local.prefix}-protocol"]
  labels       = local.common_labels

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = local.vm_boot_disk_size
      type  = local.vm_boot_disk_type
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
      condition = var.protocol_runtime == "cloud-run" ? (
        var.enable_openvpn && var.openvpn_image != "" && var.openvpn_secret_name != "" &&
        var.openvpn_secret_version != "" && var.protocol_startup_script != ""
        ) : (
        var.protocol_image != "" && var.protocol_secret_name != "" &&
        var.protocol_startup_script != "" && var.protocol_secret_version != "" && var.protocol_image_revision != ""
      )
      error_message = "The protocol VM requires a valid hybrid Xray configuration or an OpenVPN-only VM startup configuration."
    }

    precondition {
      condition     = var.protocol_runtime == "cloud-run" || (contains(var.protocol_tcp_ports, "80") && contains(var.protocol_tcp_ports, "443"))
      error_message = "The protocol VM must expose TCP 80 and 443 for HTTP redirects and TLS."
    }

    precondition {
      condition     = !var.enable_openvpn || (var.openvpn_image != "" && var.openvpn_secret_name != "" && var.openvpn_secret_version != "" && contains(var.protocol_udp_ports, "1194"))
      error_message = "OpenVPN requires its image, Secret Manager secret/version, and UDP port 1194."
    }

    precondition {
      condition     = var.protocol_zone != "" || length(data.google_compute_zones.protocol_vm.names) > 0
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

  lifecycle {
    precondition {
      condition     = length(var.protocol_tcp_ports) + length(var.protocol_udp_ports) > 0
      error_message = "At least one protocol TCP or UDP port must be enabled."
    }
  }

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
  count              = local.create_gateway_vm ? 1 : 0
  name               = "${local.prefix}-mig"
  region             = var.region
  base_instance_name = "${local.prefix}-vm"
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.gateway[0].id
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
    health_check      = google_compute_health_check.vm[0].id
    initial_delay_sec = 180
  }

  lifecycle {
    ignore_changes = [target_size]
  }
}

resource "google_compute_region_autoscaler" "gateway" {
  count  = local.create_gateway_vm ? 1 : 0
  name   = "${local.prefix}-autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.gateway[0].id

  autoscaling_policy {
    min_replicas = 1
    # Keep e2-micro's gateway disk footprint within the shared 30 GB-month allowance.
    max_replicas    = var.machine_type == "e2-micro" ? 1 : 3
    cooldown_period = 120
    cpu_utilization {
      target = 0.65
    }
  }
}

resource "google_compute_firewall" "lb_to_vm" {
  count         = local.create_gateway_vm ? 1 : 0
  name          = "${local.prefix}-allow-lb-health-checks"
  network       = google_compute_network.gateway.name
  direction     = "INGRESS"
  source_ranges = local.google_lb_ranges
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
  # Health-check probe ranges for backend service-based external passthrough Network Load Balancers.
  source_ranges = ["35.191.0.0/16", "209.85.152.0/22", "209.85.204.0/22"]
  target_tags   = ["${local.prefix}-gateway"]

  allow {
    protocol = "tcp"
    ports    = ["9000", "9443"]
  }
}

resource "google_compute_health_check" "vm" {
  depends_on = [google_project_service.required]
  count               = local.create_gateway_vm ? 1 : 0
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
  depends_on = [google_project_service.required]
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
  depends_on = [google_project_service.required]
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
  depends_on = [google_project_service.required]
  count        = local.enable_tcp_proxy ? 1 : 0
  name         = "${local.prefix}-tcp-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_address" "tls_proxy" {
  depends_on = [google_project_service.required]
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
    group          = google_compute_region_instance_group_manager.gateway[0].instance_group
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
    group          = google_compute_region_instance_group_manager.gateway[0].instance_group
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
  depends_on = [google_project_service.required]
  count       = local.use_lb ? 1 : 0
  name        = "${local.prefix}-edge-policy"
  description = "xgcpx source filtering, optional WAF, and per-client rate controls"
  type        = "CLOUD_ARMOR"

  dynamic "rule" {
    for_each = { for index, chunk in local.blocked_chunks : tostring(index) => chunk }
    content {
      action   = "deny(403)"
      priority = 100 + tonumber(rule.key)
      match {
        versioned_expr = "SRC_IPS_V1"
        config { src_ip_ranges = rule.value }
      }
      description = "Deny configured source CIDRs"
    }
  }

  dynamic "rule" {
    for_each = var.enable_waf ? [1] : []
    content {
      action   = "deny(403)"
      priority = 200
      match {
        expr { expression = "evaluatePreconfiguredWaf('sqli-v33-stable') || evaluatePreconfiguredWaf('xss-v33-stable')" }
      }
      description = "Block common SQL injection and XSS signatures"
    }
  }

  dynamic "rule" {
    for_each = { for index, chunk in local.rate_limit_scopes : tostring(index) => chunk }
    content {
      action   = "rate_based_ban"
      priority = 300 + tonumber(rule.key)
      match {
        versioned_expr = "SRC_IPS_V1"
        config { src_ip_ranges = rule.value }
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
  }

  rule {
    action   = length(var.allowed_cidrs) > 0 ? "deny(403)" : "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config { src_ip_ranges = ["*"] }
    }
    description = "Default deny when a source allowlist is configured, otherwise allow"
  }
}

resource "google_compute_global_address" "edge" {
  depends_on = [google_project_service.required]
  count = local.use_lb ? 1 : 0
  name  = "${local.prefix}-global-ip"
}

resource "google_compute_managed_ssl_certificate" "edge" {
  count = local.use_lb ? 1 : 0
  # The name includes a hash of the domain, so a replacement can be created before the old one is removed.
  name = "${local.prefix}-cert-${substr(md5(var.domain), 0, 6)}"
  managed {
    domains = [var.domain]
  }
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [google_project_service.required]
}

resource "google_compute_region_network_endpoint_group" "cloud_run" {
  count                 = local.use_lb ? 1 : 0
  name                  = "${local.prefix}-run-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run { service = google_cloud_run_v2_service.gateway.name }
}

resource "google_compute_backend_service" "cloud_run" {
  count                 = local.use_lb ? 1 : 0
  name                  = "${local.prefix}-run-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  # No timeout_sec: GCP rejects it for serverless NEG backends, whose timeout is fixed at 60 minutes,
  # matching the Cloud Run request timeout (3600s) set on the service template.
  enable_cdn      = true
  security_policy = google_compute_security_policy.edge[0].id

  # Only cache what the origin explicitly marks cacheable; tunnelled proxy traffic is never cached.
  cdn_policy {
    cache_mode = "USE_ORIGIN_HEADERS"
    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }
  }

  backend { group = google_compute_region_network_endpoint_group.cloud_run[0].id }
}

resource "google_compute_backend_service" "vm" {
  count                 = local.use_lb ? 1 : 0
  name                  = "${local.prefix}-vm-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 3600
  security_policy       = google_compute_security_policy.edge[0].id
  health_checks         = [google_compute_health_check.vm[0].id]
  backend {
    group           = google_compute_region_instance_group_manager.gateway[0].instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
  }
}

resource "google_compute_url_map" "https" {
  count           = local.use_lb ? 1 : 0
  name            = "${local.prefix}-https-map"
  default_service = google_compute_backend_service.cloud_run[0].id

  host_rule {
    hosts        = [var.domain]
    path_matcher = "gateway-routes"
  }
  path_matcher {
    name            = "gateway-routes"
    default_service = google_compute_backend_service.cloud_run[0].id
    dynamic "path_rule" {
      for_each = var.upstream_primary == local.builtin_backend ? [] : [1]
      content {
        paths   = ["/persistent/*"]
        service = google_compute_backend_service.vm[0].id
      }
    }
  }
}

resource "google_compute_target_https_proxy" "https" {
  count            = local.use_lb ? 1 : 0
  name             = "${local.prefix}-https-proxy"
  url_map          = google_compute_url_map.https[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.edge[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = local.use_lb ? 1 : 0
  name                  = "${local.prefix}-https-forwarding"
  ip_address            = google_compute_global_address.edge[0].address
  target                = google_compute_target_https_proxy.https[0].id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

resource "google_compute_url_map" "http_redirect" {
  count = local.use_lb ? 1 : 0
  name  = "${local.prefix}-http-redirect"
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

resource "google_compute_target_http_proxy" "http_redirect" {
  count   = local.use_lb ? 1 : 0
  name    = "${local.prefix}-http-proxy"
  url_map = google_compute_url_map.http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  count                 = local.use_lb ? 1 : 0
  name                  = "${local.prefix}-http-forwarding"
  ip_address            = google_compute_global_address.edge[0].address
  target                = google_compute_target_http_proxy.http_redirect[0].id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
