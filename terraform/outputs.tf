output "load_balancer_ip" {
  description = "Global external load balancer IPv4 address."
  value       = google_compute_global_address.edge.address
}

output "https_url" {
  description = "Public HTTPS endpoint. Certificate activation requires DNS to point at load_balancer_ip."
  value       = "https://${var.domain}"
}

output "cloud_run_service" {
  description = "Deployed Cloud Run service name."
  value       = google_cloud_run_v2_service.gateway.name
}

output "vm_managed_group" {
  description = "Regional persistent Compute Engine managed instance group."
  value       = google_compute_region_instance_group_manager.gateway.name
}

output "tcp_proxy_ip" {
  description = "Regional TCP proxy address; null unless Envoy TCP/TLS is enabled."
  value       = try(google_compute_address.tcp_proxy[0].address, null)
}

output "tls_proxy_ip" {
  description = "Regional TLS passthrough address; null unless Envoy TCP/TLS is enabled."
  value       = try(google_compute_address.tls_proxy[0].address, null)
}

output "protocol_gateway_ip" {
  description = "Dedicated public IP for the authenticated protocol VM; null when it is disabled."
  value       = try(google_compute_address.protocol_vm[0].address, null)
}