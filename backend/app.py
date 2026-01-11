from flask import Flask, request, jsonify, make_response
from flask_cors import CORS
import psycopg2
from psycopg2.extras import RealDictCursor
import os
from werkzeug.security import generate_password_hash, check_password_hash
import jwt
from datetime import datetime, timedelta
from functools import wraps
import csv
from io import StringIO

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', 'dev-secret-key-change-in-production')

# Enable CORS for the frontend
CORS(app, supports_credentials=True, origins=["http://localhost", "http://localhost:80", "http://127.0.0.1:80"])

# Database connection function
def get_db_connection():
    conn = psycopg2.connect(
        host=os.environ.get('DB_HOST', 'localhost'),
        database=os.environ.get('DB_NAME', 'telephone_auth'),
        user=os.environ.get('DB_USER', 'postgres'),
        password=os.environ.get('DB_PASSWORD', 'password')
    )
    return conn

# Token verification decorator
def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get('Authorization')
        
        if not token:
            return jsonify({'error': 'Token is missing'}), 401
        
        try:
            # Remove 'Bearer ' prefix if present
            if token.startswith('Bearer '):
                token = token[7:]
            
            data = jwt.decode(token, app.secret_key, algorithms=['HS256'])
            current_user_id = data['user_id']
            
            conn = get_db_connection()
            cur = conn.cursor(cursor_factory=RealDictCursor)
            cur.execute('SELECT id, username FROM users WHERE id = %s', (current_user_id,))
            current_user = cur.fetchone()
            cur.close()
            conn.close()
            
            if not current_user:
                return jsonify({'error': 'User not found'}), 401
                
        except jwt.ExpiredSignatureError:
            return jsonify({'error': 'Token has expired'}), 401
        except jwt.InvalidTokenError:
            return jsonify({'error': 'Invalid token'}), 401
        
        return f(current_user, *args, **kwargs)
    
    return decorated

# Initialize database tables
def init_database():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        print('Initializing database schema...')
        
        # Create users table if not exists
        cur.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id SERIAL PRIMARY KEY,
                username VARCHAR(100) UNIQUE NOT NULL,
                password VARCHAR(255) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        # Add password column if it doesn't exist (migration)
        cur.execute('''
            DO $$ 
            BEGIN 
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns 
                    WHERE table_name='users' AND column_name='password'
                ) THEN
                    ALTER TABLE users ADD COLUMN password VARCHAR(255);
                END IF;
            END $$;
        ''')
        
        # Create contacts table if not exists
        cur.execute('''
            CREATE TABLE IF NOT EXISTS contacts (
                id SERIAL PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                name VARCHAR(255) NOT NULL,
                phone VARCHAR(50) NOT NULL,
                address TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        # Add address column if it doesn't exist (migration)
        cur.execute('''
            DO $$ 
            BEGIN 
                IF NOT EXISTS (
                    SELECT 1 FROM information_schema.columns 
                    WHERE table_name='contacts' AND column_name='address'
                ) THEN
                    ALTER TABLE contacts ADD COLUMN address TEXT;
                END IF;
            END $$;
        ''')
        
        # Create secrets table if not exists
        cur.execute('''
            CREATE TABLE IF NOT EXISTS secrets (
                id SERIAL PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                title VARCHAR(255) NOT NULL,
                category VARCHAR(50) DEFAULT 'general',
                username VARCHAR(255),
                password TEXT,
                api_key TEXT,
                url TEXT,
                notes TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        # Create indexes
        cur.execute('CREATE INDEX IF NOT EXISTS idx_contacts_user_id ON contacts(user_id)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_secrets_user_id ON secrets(user_id)')
        cur.execute('CREATE INDEX IF NOT EXISTS idx_secrets_category ON secrets(category)')
        
        conn.commit()
        cur.close()
        conn.close()
        print('✓ Database tables initialized')
        return True
    except Exception as e:
        print(f'✗ Database initialization failed: {e}')
        import traceback
        traceback.print_exc()
        return False

# Create default admin user on startup
def create_default_admin():
    try:
        conn = get_db_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        
        # Check if admin user exists
        cur.execute('SELECT id FROM users WHERE username = %s', ('admin',))
        existing_user = cur.fetchone()
        
        if not existing_user:
            # Create admin user with password 'admin'
            hashed_password = generate_password_hash('admin')
            cur.execute(
                'INSERT INTO users (username, password) VALUES (%s, %s)',
                ('admin', hashed_password)
            )
            conn.commit()
            print('✓ Default admin user created (username: admin, password: admin)')
        else:
            print('✓ Admin user already exists')
        
        cur.close()
        conn.close()
    except Exception as e:
        print(f'✗ Could not create default admin user: {e}')
        import traceback
        traceback.print_exc()

# Health check endpoint
@app.route('/health', methods=['GET'])
def health_check():
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute('SELECT 1')
        cur.close()
        conn.close()
        return jsonify({'status': 'healthy', 'database': 'connected'}), 200
    except Exception as e:
        return jsonify({'status': 'unhealthy', 'error': str(e)}), 503

# ============================================================================
# AUTHENTICATION ENDPOINTS
# ============================================================================

@app.route('/api/register', methods=['POST'])
def register():
    data = request.get_json()
    username = data.get('username')
    password = data.get('password')

    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400

    hashed_password = generate_password_hash(password)

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            'INSERT INTO users (username, password) VALUES (%s, %s) RETURNING id',
            (username, hashed_password)
        )
        user_id = cur.fetchone()[0]
        conn.commit()
        
        # Generate token
        token = jwt.encode({
            'user_id': user_id,
            'exp': datetime.utcnow() + timedelta(days=7)
        }, app.secret_key, algorithm='HS256')
        
        return jsonify({
            'message': 'Registration successful',
            'token': token,
            'username': username
        })
    except psycopg2.IntegrityError:
        conn.rollback()
        return jsonify({'error': 'Username already exists'}), 400
    finally:
        cur.close()
        conn.close()

@app.route('/api/login', methods=['POST'])
def login():
    data = request.get_json()
    username = data.get('username')
    password = data.get('password')

    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute('SELECT id, username, password FROM users WHERE username = %s', (username,))
    user = cur.fetchone()
    cur.close()
    conn.close()

    if user and check_password_hash(user['password'], password):
        # Generate token
        token = jwt.encode({
            'user_id': user['id'],
            'exp': datetime.utcnow() + timedelta(days=7)
        }, app.secret_key, algorithm='HS256')
        
        return jsonify({
            'message': 'Login successful',
            'token': token,
            'username': user['username']
        })
    else:
        return jsonify({'error': 'Invalid username or password'}), 401

@app.route('/api/logout', methods=['POST'])
def logout():
    return jsonify({'message': 'Logged out'})

@app.route('/api/current_user', methods=['GET'])
@token_required
def current_user(user):
    return jsonify({'username': user['username']})

# ============================================================================
# CONTACTS ENDPOINTS
# ============================================================================

@app.route('/api/contacts', methods=['GET'])
@token_required
def get_contacts(current_user):
    search = request.args.get('search', '')
    
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    if search:
        # Search in name, phone, and address
        search_pattern = f'%{search}%'
        cur.execute('''
            SELECT id, name, phone, address 
            FROM contacts 
            WHERE user_id = %s 
            AND (name ILIKE %s OR phone ILIKE %s OR COALESCE(address, '') ILIKE %s)
            ORDER BY name
        ''', (current_user['id'], search_pattern, search_pattern, search_pattern))
    else:
        cur.execute('SELECT id, name, phone, address FROM contacts WHERE user_id = %s ORDER BY name', (current_user['id'],))
    
    contacts = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(contacts)

@app.route('/api/contacts', methods=['POST'])
@token_required
def add_contact(current_user):
    data = request.get_json()
    name = data.get('name')
    phone = data.get('phone')
    address = data.get('address', '')

    if not name or not phone:
        return jsonify({'error': 'Name and phone required'}), 400

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        'INSERT INTO contacts (user_id, name, phone, address) VALUES (%s, %s, %s, %s)',
        (current_user['id'], name, phone, address)
    )
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'message': 'Contact added successfully'})

@app.route('/api/contacts/<int:contact_id>', methods=['PUT'])
@token_required
def update_contact(current_user, contact_id):
    data = request.get_json()
    name = data.get('name')
    phone = data.get('phone')
    address = data.get('address', '')

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        'UPDATE contacts SET name = %s, phone = %s, address = %s WHERE id = %s AND user_id = %s',
        (name, phone, address, contact_id, current_user['id'])
    )
    conn.commit()
    affected = cur.rowcount
    cur.close()
    conn.close()

    if affected == 0:
        return jsonify({'error': 'Contact not found'}), 404
    return jsonify({'message': 'Contact updated successfully'})

@app.route('/api/contacts/<int:contact_id>', methods=['DELETE'])
@token_required
def delete_contact(current_user, contact_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        'DELETE FROM contacts WHERE id = %s AND user_id = %s',
        (contact_id, current_user['id'])
    )
    conn.commit()
    affected = cur.rowcount
    cur.close()
    conn.close()

    if affected == 0:
        return jsonify({'error': 'Contact not found'}), 404
    return jsonify({'message': 'Contact deleted successfully'})

@app.route('/api/contacts/export', methods=['GET'])
@token_required
def export_contacts(current_user):
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute('SELECT name, phone, address FROM contacts WHERE user_id = %s ORDER BY name', (current_user['id'],))
    contacts = cur.fetchall()
    cur.close()
    conn.close()
    
    # Create CSV
    output = StringIO()
    writer = csv.DictWriter(output, fieldnames=['name', 'phone', 'address'])
    writer.writeheader()
    for contact in contacts:
        writer.writerow(contact)
    
    # Return as downloadable file
    csv_output = output.getvalue()
    response = make_response(csv_output)
    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=contacts.csv'
    return response

# ============================================================================
# SECRETS ENDPOINTS
# ============================================================================

@app.route('/api/secrets', methods=['GET'])
@token_required
def get_secrets(current_user):
    search = request.args.get('search', '')
    category = request.args.get('category', '')
    
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    query = 'SELECT id, title, category, username, url, created_at FROM secrets WHERE user_id = %s'
    params = [current_user['id']]
    
    if search:
        query += ' AND (title ILIKE %s OR username ILIKE %s OR url ILIKE %s)'
        search_pattern = f'%{search}%'
        params.extend([search_pattern, search_pattern, search_pattern])
    
    if category:
        query += ' AND category = %s'
        params.append(category)
    
    query += ' ORDER BY created_at DESC'
    
    cur.execute(query, params)
    secrets = cur.fetchall()
    cur.close()
    conn.close()
    return jsonify(secrets)

@app.route('/api/secrets/<int:secret_id>', methods=['GET'])
@token_required
def get_secret(current_user, secret_id):
    conn = get_db_connection()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute(
        'SELECT id, title, category, username, password, api_key, url, notes, created_at FROM secrets WHERE id = %s AND user_id = %s',
        (secret_id, current_user['id'])
    )
    secret = cur.fetchone()
    cur.close()
    conn.close()
    
    if not secret:
        return jsonify({'error': 'Secret not found'}), 404
    
    return jsonify(secret)

@app.route('/api/secrets', methods=['POST'])
@token_required
def add_secret(current_user):
    data = request.get_json()
    title = data.get('title')
    category = data.get('category', 'general')
    username = data.get('username', '')
    password = data.get('password', '')
    api_key = data.get('api_key', '')
    url = data.get('url', '')
    notes = data.get('notes', '')

    if not title:
        return jsonify({'error': 'Title is required'}), 400

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        '''INSERT INTO secrets (user_id, title, category, username, password, api_key, url, notes) 
           VALUES (%s, %s, %s, %s, %s, %s, %s, %s)''',
        (current_user['id'], title, category, username, password, api_key, url, notes)
    )
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'message': 'Secret added successfully'})

@app.route('/api/secrets/<int:secret_id>', methods=['PUT'])
@token_required
def update_secret(current_user, secret_id):
    data = request.get_json()
    title = data.get('title')
    category = data.get('category', 'general')
    username = data.get('username', '')
    password = data.get('password', '')
    api_key = data.get('api_key', '')
    url = data.get('url', '')
    notes = data.get('notes', '')

    if not title:
        return jsonify({'error': 'Title is required'}), 400

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        '''UPDATE secrets 
           SET title = %s, category = %s, username = %s, password = %s, api_key = %s, url = %s, notes = %s 
           WHERE id = %s AND user_id = %s''',
        (title, category, username, password, api_key, url, notes, secret_id, current_user['id'])
    )
    conn.commit()
    affected = cur.rowcount
    cur.close()
    conn.close()

    if affected == 0:
        return jsonify({'error': 'Secret not found'}), 404
    return jsonify({'message': 'Secret updated successfully'})

@app.route('/api/secrets/<int:secret_id>', methods=['DELETE'])
@token_required
def delete_secret(current_user, secret_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        'DELETE FROM secrets WHERE id = %s AND user_id = %s',
        (secret_id, current_user['id'])
    )
    conn.commit()
    affected = cur.rowcount
    cur.close()
    conn.close()

    if affected == 0:
        return jsonify({'error': 'Secret not found'}), 404
    return jsonify({'message': 'Secret deleted successfully'})

# Initialize database and create admin user on startup (works with Gunicorn)
try:
    if init_database():
        create_default_admin()
except Exception as e:
    print(f'Startup initialization error: {e}')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)