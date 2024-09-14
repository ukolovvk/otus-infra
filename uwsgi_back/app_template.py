from flask import Flask, request, jsonify
import redis

app = Flask(__name__)

r = redis.Redis(host='${ redis_vm_ip }', port=6379, db=0)

@app.route('/', methods=['GET'])
def get_default():
    return "Flask App Default"

@app.route('/get/<key>', methods=['GET'])
def get_value(key):
    value = r.get(key)
    if value:
        return jsonify({key: value.decode('utf-8')}), 200
    return jsonify({'error': 'Key not found'}), 404

@app.route('/set', methods=['POST'])
def set_value():
    data = request.json
    if 'key' not in data or 'value' not in data:
        return jsonify({'error': 'Key and value required'}), 400
    r.set(data['key'], data['value'])
    return jsonify({'message': 'Key set successfully'}), 201

@app.route('/delete/<key>', methods=['DELETE'])
def delete_value(key):
    result = r.delete(key)
    if result:
        return jsonify({'message': 'Key deleted successfully'}), 200
    return jsonify({'error': 'Key not found'}), 404

if __name__ == '__main__':
     app.run(host='0.0.0.0')
