-- Drop and recreate users table with correct schema
DROP TABLE IF EXISTS secrets CASCADE;
DROP TABLE IF EXISTS contacts CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- Create users table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(100) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create contacts table
CREATE TABLE contacts (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    phone VARCHAR(50) NOT NULL,
    address TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create secrets table
CREATE TABLE secrets (
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
);

-- Create indexes
CREATE INDEX idx_contacts_user_id ON contacts(user_id);
CREATE INDEX idx_secrets_user_id ON secrets(user_id);
CREATE INDEX idx_secrets_category ON secrets(category);

-- Create default admin user (password is 'admin')
-- Hash generated with: python3 -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('admin'))"
INSERT INTO users (username, password) 
VALUES ('admin', 'scrypt:32768:8:1$ujOmUr8YpoiFYolV$9488d44bb91715ba14653b75acdbe0b865e882d0479dcd8f5da814444c89817cd4b93b6f756d63b99da241ea2dcc67e67539d51c8e8af86802a6cfce216614a9');

-- Insert sample contacts for admin user
INSERT INTO contacts (user_id, name, phone, address) VALUES
    (1, 'John Doe', '+1-555-0101', '123 Main St, New York, NY 10001'),
    (1, 'Jane Smith', '+1-555-0102', '456 Oak Ave, Los Angeles, CA 90001'),
    (1, 'Bob Johnson', '+1-555-0103', '789 Pine Rd, Chicago, IL 60601'),
    (1, 'Alice Williams', '+1-555-0104', '321 Elm St, Houston, TX 77001'),
    (1, 'Charlie Brown', '+1-555-0105', '654 Maple Dr, Phoenix, AZ 85001'),
    (1, 'David Lee', '+1-555-0106', '987 Cedar Ln, Philadelphia, PA 19101'),
    (1, 'Emma Davis', '+1-555-0107', '147 Birch Ct, San Antonio, TX 78201'),
    (1, 'Frank Miller', '+1-555-0108', '258 Spruce Way, San Diego, CA 92101'),
    (1, 'Grace Wilson', '+1-555-0109', '369 Willow Pl, Dallas, TX 75201'),
    (1, 'Henry Taylor', '+1-555-0110', '741 Ash Blvd, San Jose, CA 95101');

-- Insert sample secrets for admin user
INSERT INTO secrets (user_id, title, category, username, password, url, notes) VALUES
    (1, 'Gmail Account', 'password', 'admin@example.com', 'MySecureP@ssw0rd!', 'https://gmail.com', 'Personal email account'),
    (1, 'GitHub', 'password', 'admin_dev', 'GitH@b2024Secure!', 'https://github.com', 'Development account'),
    (1, 'AWS Console', 'password', 'admin.aws', 'AWS#Prod2024!', 'https://console.aws.amazon.com', 'Production AWS account'),
    (1, 'OpenAI API Key', 'api', NULL, NULL, 'https://platform.openai.com', 'sk-proj-1234567890abcdef'),
    (1, 'Stripe API Key', 'api', NULL, NULL, 'https://stripe.com', 'sk_live_abcdefghijklmnop'),
    (1, 'Production Database', 'database', 'db_admin', 'ProdDB#2024!Secure', 'postgresql://prod-db.example.com:5432', 'Main production database credentials'),
    (1, 'SSH Server Key', 'general', 'root', NULL, 'ssh://server.example.com', 'Private key stored in /home/admin/.ssh/id_rsa'),
    (1, 'Slack Workspace', 'password', 'admin@company.com', 'Sl@ckTeam2024!', 'https://company.slack.com', 'Company Slack workspace'),
    (1, 'Twitter API', 'api', NULL, NULL, 'https://developer.twitter.com', 'Bearer token: AAAAAAAAAAAAAAAAAAAAABearerToken123456'),
    (1, 'WiFi Password', 'general', NULL, 'WiFi#Home2024!', NULL, 'Home WiFi network password');