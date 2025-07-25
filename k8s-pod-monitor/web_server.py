import threading
import time
import json
from datetime import datetime, timedelta
from pathlib import Path

try:
    from flask import Flask, render_template, jsonify
    from flask_cors import CORS
except ImportError: exit("ERROR: 'flask' or 'flask-cors' not found. Please run build script.")

from main import check_all_clusters, save_to_file, load_from_file, analyze_changes

app = Flask(__name__)
CORS(app)
background_task_lock = threading.Lock()
background_thread_status = {"running": False, "last_run": "Never", "last_result": "N/A"}
cached_data = {}

@app.route('/')
def dashboard(): return render_template('dashboard.html')

@app.route('/api/data')
def get_api_data():
    if not cached_data:
        print("INFO: No cached data found. Running initial scan...")
        run_monitor_check()
    response_data = cached_data.copy()
    response_data['background_status'] = background_thread_status
    return jsonify(response_data)

@app.route('/api/run-check', methods=['POST'])
def force_run_check():
    if background_task_lock.locked():
        return jsonify({"status": "error", "message": "A scan is already in progress."}), 429
    thread = threading.Thread(target=run_monitor_check)
    thread.start()
    return jsonify({"status": "success", "message": "A new multi-cluster pod scan has been initiated."})

def run_monitor_check():
    global cached_data
    with background_task_lock:
        print("INFO: Acquiring lock for multi-cluster monitor check...")
        background_thread_status["running"] = True
        today = datetime.now()
        try:
            today_pods = check_all_clusters()
            save_to_file(today_pods, today)
        except Exception as e:
            background_thread_status["last_result"] = f"Failed: {e}"
            background_thread_status["running"] = False
            return
        
        yesterday = today - timedelta(days=1)
        yesterday_pods = load_from_file(yesterday)
        analysis_result = analyze_changes(today_pods, yesterday_pods)
        cached_data = format_data_for_dashboard(today_pods, analysis_result)
        background_thread_status.update({"last_run": today.strftime('%Y-%m-%d %H:%M:%S'), "last_result": "Success", "running": False})
        print("INFO: Multi-cluster monitor check completed and data cached.")

def format_data_for_dashboard(today_pods, analysis):
    status_counts, cluster_counts = {}, {}
    for pod in today_pods:
        status_counts[pod['status']] = status_counts.get(pod['status'], 0) + 1
        cluster_counts[pod['cluster']] = cluster_counts.get(pod['cluster'], 0) + 1
    return {
        "stats": {"total": len(today_pods), "new": len(analysis['new']), "ongoing": len(analysis['ongoing']), "resolved": len(analysis['resolved'])},
        "lists": analysis,
        "charts": {
            "status_distribution": {"labels": list(status_counts.keys()), "values": list(status_counts.values())},
            "cluster_distribution": {"labels": list(cluster_counts.keys()), "values": list(cluster_counts.values())}
        },
        "last_updated": datetime.now().isoformat()
    }

def background_scheduler():
    print("INFO: Background scheduler started. Will run checks every 10 minutes.")
    while True:
        run_monitor_check()
        time.sleep(600)

if __name__ == '__main__':
    port = 5000
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        if s.connect_ex(('localhost', port)) == 0:
            exit(f"ERROR: Port {port} is already in use.")
    run_monitor_check()
    scheduler_thread = threading.Thread(target=background_scheduler, daemon=True)
    scheduler_thread.start()
    print(f"INFO: Starting Flask web server on http://localhost:{port}")
    app.run(host='0.0.0.0', port=port, debug=False)
