use kube::{Client, api::{Api, ResourceExt}};
use k8s_openapi::api::core::v1::Node;
use anyhow::Result;

#[tokio::main]
async fn main() -> Result<()> {
    let client = Client::try_default().await?;
    let nodes: Api<Node> = Api::all(client);
    let node_list = nodes.list(&Default::default()).await?;

    for node in node_list.items {
        let name = node.name_any();
        let status = node.status.unwrap_or_default();
        let capacity = status.capacity.unwrap_or_default();
        let allocatable = status.allocatable.unwrap_or_default();

        println!("🖥️ Node: {}", name);
        println!("-----------------------------------");

        // CPU
        println!("📦 CPU:");
        println!("  Capacity:    {}", capacity.get("cpu").map_or("-", |q| q.0.as_str()));
        println!("  Allocatable: {}", allocatable.get("cpu").map_or("-", |q| q.0.as_str()));
        println!();

        // Memory
        println!("💾 Memory:");
        println!("  Capacity:    {}", capacity.get("memory").map_or("-", |q| q.0.as_str()));
        println!("  Allocatable: {}", allocatable.get("memory").map_or("-", |q| q.0.as_str()));
        println!();

        // GPU
        println!("🎮 GPU:");
        println!("  Capacity:    {}", capacity.get("nvidia.com/gpu").map_or("0", |q| q.0.as_str()));
        println!("  Allocatable: {}", allocatable.get("nvidia.com/gpu").map_or("0", |q| q.0.as_str()));
        println!();

        // MIG GPU 리소스
        println!("🔹 MIG GPU Instances:");
        for (key, val) in capacity.iter() {
            if key.starts_with("nvidia.com/mig") {
                let alloc_val = allocatable.get(key);
                println!(
                    "  {} -> Capacity: {}, Allocatable: {}",
                    key,
                    val.0,
                    alloc_val.map_or("0", |q| q.0.as_str())
                );
            }
        }

        println!("\n===============================\n");
    }

    Ok(())
}
