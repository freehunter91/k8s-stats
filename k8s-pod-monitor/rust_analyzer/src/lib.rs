use pyo3::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Serialize, Deserialize, Debug, Clone, Hash, Eq, PartialEq)]
struct PodInfo { cluster: String, namespace: String, pod: String }

#[derive(Serialize, Deserialize, Debug)]
struct AnalysisResult { new: Vec<PodInfo>, ongoing: Vec<PodInfo>, resolved: Vec<PodInfo> }

#[pyfunction]
fn analyze_pod_changes(today_pods_str: String, yesterday_pods_str: String) -> PyResult<String> {
    let today_pods: Vec<PodInfo> = serde_json::from_str(&today_pods_str).map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to parse today's pods JSON: {}", e)))?;
    let yesterday_pods: Vec<PodInfo> = serde_json::from_str(&yesterday_pods_str).map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to parse yesterday's pods JSON: {}", e)))?;
    let today_set: HashSet<PodInfo> = today_pods.into_iter().collect();
    let yesterday_set: HashSet<PodInfo> = yesterday_pods.into_iter().collect();
    let new: Vec<PodInfo> = today_set.difference(&yesterday_set).cloned().collect();
    let ongoing: Vec<PodInfo> = today_set.intersection(&yesterday_set).cloned().collect();
    let resolved: Vec<PodInfo> = yesterday_set.difference(&today_set).cloned().collect();
    let result = AnalysisResult { new, ongoing, resolved };
    serde_json::to_string(&result).map_err(|e| PyErr::new::<pyo3::exceptions::PyValueError, _>(format!("Failed to serialize result to JSON: {}", e)))
}

#[pymodule]
fn rust_analyzer(_py: Python, m: &PyModule) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(analyze_pod_changes, m)?)?;
    Ok(())
}
