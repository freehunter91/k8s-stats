import threading, time, json, io
from datetime import datetime, timedelta
import pandas as pd
from flask import Flask, render_template, jsonify, request, send_file
from flask_cors import CORS
from main import check_all_clusters, save_to_file, load_from_file, analyze_changes, get_pod_events

app = Flask(__name__)
CORS(app)
background_task_lock, background_thread_status, cached_data = threading.Lock(), {"running": False, "last_run": "Never", "last_result": "N/A"}, {}

@app.route('/')
def dashboard(): return render_template('dashboard.html')

@app.route('/api/data')
def get_api_data():
    if not cached_data: run_monitor_check()
    return jsonify({**cached_data, 'background_status': background_thread_status})

@app.route('/api/pod/events')
def pod_events_api():
    context, namespace, pod = request.args.get('context'), request.args.get('namespace'), request.args.get('pod')
    if not all([context, namespace, pod]): return jsonify({"error": "Missing parameters"}), 400
    return jsonify(get_pod_events(context, namespace, pod))

@app.route('/api/download/excel')
def download_excel():
    if not cached_data: return "No data available, please refresh.", 404
    
    todays_issues = cached_data['lists']['new'] + cached_data['lists']['ongoing']
    
    # Add detailed events to each pod record for the Excel file
    all_pod_details = []
    for pod in todays_issues:
        pod_details = pod.copy()
        events = get_pod_events(pod['context_name'], pod['namespace'], pod['pod'])
        event_strings = [f"[{e.get('last_seen', 'N/A')}] ({e.get('type', 'N/A')}) {e.get('reason', 'N/A')}: {e.get('message', 'N/A')}" for e in events]
        pod_details['detailed_events'] = "\n".join(event_strings) if event_strings else "No events found."
        all_pod_details.append(pod_details)
        
    if not all_pod_details:
        df = pd.DataFrame(columns=['cluster', 'namespace', 'pod', 'node', 'status', 'reasons', 'detailed_events', 'timestamp'])
    else:
        df = pd.DataFrame(all_pod_details)
        # Reorder columns for the final Excel output
        df = df[['cluster', 'namespace', 'pod', 'node', 'status', 'reasons', 'detailed_events', 'timestamp']]
    
    output = io.BytesIO()
    df.to_excel(output, index=False, sheet_name='Abnormal_Pods')
    output.seek(0)
    
    filename = f"abnormal_pods_{datetime.now().strftime('%Y-%m-%d')}.xlsx"
    return send_file(output, as_attachment=True, download_name=filename, 
                     mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')

@app.route('/api/run-check', methods=['POST'])
def force_run_check():
    if background_task_lock.locked(): return jsonify({"status": "error", "message": "Scan in progress."}), 429
    threading.Thread(target=run_monitor_check).start()
    return jsonify({"status": "success", "message": "New scan initiated."})

def run_monitor_check():
    with background_task_lock:
        print("INFO: Acquiring lock for monitor check...")
        background_thread_status["running"] = True
        today = datetime.now()
        try:
            today_pods = check_all_clusters()
            save_to_file(today_pods, today)
        except Exception as e:
            background_thread_status.update({"last_result": f"Failed: {e}", "running": False}); return
        
        global cached_data
        cached_data = format_data_for_dashboard(today_pods, analyze_changes(today_pods, load_from_file(today - timedelta(days=1))))
        background_thread_status.update({"last_run": today.strftime('%Y-%m-%d %H:%M:%S'), "last_result": "Success", "running": False})
        print("INFO: Monitor check completed.")

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
        }, "last_updated": datetime.now().isoformat()
    }

def background_scheduler():
    print("INFO: Background scheduler started.")
    while True:
        run_monitor_check(); time.sleep(600)

if __name__ == '__main__':
    port = 5000
    run_monitor_check()
    threading.Thread(target=background_scheduler, daemon=True).start()
    print(f"INFO: Starting Flask web server on http://0.0.0.0:{port}")
    app.run(host='0.0.0.0', port=port, debug=False)
