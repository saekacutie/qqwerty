output "load_balancer_ip" {
  description = "Global external load balancer IPv4 address; null in automatic Cloud Run host mode."
  value       = try(google_compute_global_address.edge[0].address, null)
}

output "https_url" {
  description = "Public HTTPS endpoint. The real run.app URL in automatic mode; otherwise your domain (certificate activation requires DNS to point at load_balancer_ip)."
  value       = var.use_cloud_run_host ? google_cloud_run_v2_service.gateway.uri : "https://${var.domain}"
}

output "cloud_run_service" {
  description = "Deployed Cloud Run service name."
  value       = google_cloud_run_v2_service.gateway.name
}

output "vm_managed_group" {
  description = "Regional gateway managed instance group; null when no gateway VM exists."
  value       = try(google_compute_region_instance_group_manager.gateway[0].name, null)
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
  description = "Dedicated public IP for the protocol VM; null when it is disabled."
  value       = try(google_compute_address.protocol_vm[0].address, null)
}
