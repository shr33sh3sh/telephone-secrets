// Configuration
const API_BASE_URL = '/api/secrets';

// Global state
let currentEditSecret = null;
let searchTimeout;

// Auth fetch wrapper
async function authFetch(url, options = {}) {
    const token = localStorage.getItem('token');
    
    if (!token) {
        redirectToLogin('No authentication token found');
        return null;
    }

    const headers = {
        'Authorization': `Bearer ${token}`,
        ...(options.headers || {})
    };
    
    if (options.body && typeof options.body === 'string') {
        headers['Content-Type'] = 'application/json';
    }

    try {
        const response = await fetch(url, { ...options, headers });

        if (response.status === 401) {
            redirectToLogin('Session expired. Please log in again.');
            return null;
        }

        return response;
    } catch (error) {
        console.error('Network error:', error);
        alert('Network error. Please check your connection.');
        return null;
    }
}

function redirectToLogin(message) {
    if (message) alert(message);
    localStorage.removeItem('token');
    window.location.href = '/';
}

// Debounce search
function debounceSearch(search, category) {
    clearTimeout(searchTimeout);
    searchTimeout = setTimeout(() => loadSecrets(search, category), 300);
}

// Load secrets
async function loadSecrets(search = '', category = '') {
    try {
        let url = API_BASE_URL;
        const params = new URLSearchParams();
        
        if (search) params.append('search', search);
        if (category) params.append('category', category);
        
        if (params.toString()) url += `?${params.toString()}`;
        
        const response = await authFetch(url);
        if (!response) return;

        if (!response.ok) {
            throw new Error('Failed to load secrets');
        }

        const secrets = await response.json();
        displaySecrets(secrets);
    } catch (error) {
        console.error('Error loading secrets:', error);
        alert(error.message || 'Failed to load secrets');
    }
}

// Display secrets
function displaySecrets(secrets) {
    const container = document.getElementById('secretsContainer');
    container.innerHTML = '';

    if (!secrets || secrets.length === 0) {
        container.innerHTML = `
            <div class="empty-state">
                <div class="empty-state-icon">🔒</div>
                <p>No secrets found. Click "Add Secret" to create one!</p>
            </div>
        `;
        return;
    }

    secrets.forEach(secret => {
        const card = document.createElement('div');
        card.className = 'secret-card';
        
        const categoryClass = `category-${secret.category || 'general'}`;
        const icon = getCategoryIcon(secret.category);
        
        card.innerHTML = `
            <h3>
                ${icon} ${escapeHtml(secret.title)}
            </h3>
            <span class="category-badge ${categoryClass}">${secret.category || 'general'}</span>
            <div class="secret-info">
                ${secret.username ? `<div>👤 ${escapeHtml(secret.username)}</div>` : ''}
                ${secret.url ? `<div>🔗 <a href="${escapeHtml(secret.url)}" target="_blank" rel="noopener">${escapeHtml(secret.url)}</a></div>` : ''}
                <div style="font-size: 12px; color: #999; margin-top: 10px;">
                    Created: ${formatDate(secret.created_at)}
                </div>
            </div>
            <div class="secret-actions">
                <button onclick="viewSecret(${secret.id})" class="btn-view">View</button>
                <button onclick="editSecret(${secret.id})" class="btn-edit">Edit</button>
                <button onclick="deleteSecret(${secret.id})" class="btn-delete">Delete</button>
            </div>
        `;
        
        container.appendChild(card);
    });
}

function getCategoryIcon(category) {
    const icons = {
        'password': '🔑',
        'api': '🔌',
        'database': '🗄️',
        'general': '📝'
    };
    return icons[category] || icons.general;
}

// Add new secret
function addSecret() {
    currentEditSecret = null;
    document.getElementById('modalTitle').textContent = 'Add Secret';
    document.getElementById('secretForm').reset();
    document.getElementById('secretModal').style.display = 'block';
}

// Edit secret
async function editSecret(id) {
    try {
        const response = await authFetch(`${API_BASE_URL}/${id}`);
        if (!response) return;
        
        if (!response.ok) {
            throw new Error('Failed to fetch secret');
        }
        
        const secret = await response.json();
        currentEditSecret = secret;
        
        document.getElementById('modalTitle').textContent = 'Edit Secret';
        document.getElementById('editTitle').value = secret.title || '';
        document.getElementById('editCategory').value = secret.category || 'general';
        document.getElementById('editUsername').value = secret.username || '';
        document.getElementById('editPassword').value = secret.password || '';
        document.getElementById('editApiKey').value = secret.api_key || '';
        document.getElementById('editUrl').value = secret.url || '';
        document.getElementById('editNotes').value = secret.notes || '';
        
        document.getElementById('secretModal').style.display = 'block';
    } catch (error) {
        console.error('Error fetching secret:', error);
        alert('Failed to load secret details');
    }
}

// View secret
async function viewSecret(id) {
    try {
        const response = await authFetch(`${API_BASE_URL}/${id}`);
        if (!response) return;
        
        if (!response.ok) {
            throw new Error('Failed to fetch secret');
        }
        
        const secret = await response.json();
        
        const content = document.getElementById('viewContent');
        content.innerHTML = `
            <div style="margin: 20px 0;">
                <h4 style="margin-bottom: 15px; color: #333;">${escapeHtml(secret.title)}</h4>
                <div style="background: #f9f9f9; padding: 15px; border-radius: 4px;">
                    ${secret.username ? `
                        <div style="margin-bottom: 10px;">
                            <strong>Username/Email:</strong><br>
                            <span style="font-family: monospace;">${escapeHtml(secret.username)}</span>
                            <button onclick="copyToClipboard('${escapeHtml(secret.username)}')" class="btn-copy" style="margin-left: 10px;">Copy</button>
                        </div>
                    ` : ''}
                    ${secret.password ? `
                        <div style="margin-bottom: 10px;">
                            <strong>Password:</strong><br>
                            <span style="font-family: monospace;">••••••••</span>
                            <button onclick="copyToClipboard('${escapeHtml(secret.password)}')" class="btn-copy" style="margin-left: 10px;">Copy</button>
                            <button onclick="revealPassword(this, '${escapeHtml(secret.password)}')" class="btn-view" style="margin-left: 5px;">Show</button>
                        </div>
                    ` : ''}
                    ${secret.api_key ? `
                        <div style="margin-bottom: 10px;">
                            <strong>API Key:</strong><br>
                            <span style="font-family: monospace;">••••••••</span>
                            <button onclick="copyToClipboard('${escapeHtml(secret.api_key)}')" class="btn-copy" style="margin-left: 10px;">Copy</button>
                            <button onclick="revealPassword(this, '${escapeHtml(secret.api_key)}')" class="btn-view" style="margin-left: 5px;">Show</button>
                        </div>
                    ` : ''}
                    ${secret.url ? `
                        <div style="margin-bottom: 10px;">
                            <strong>URL:</strong><br>
                            <a href="${escapeHtml(secret.url)}" target="_blank" rel="noopener">${escapeHtml(secret.url)}</a>
                        </div>
                    ` : ''}
                    ${secret.notes ? `
                        <div style="margin-bottom: 10px;">
                            <strong>Notes:</strong><br>
                            <div style="white-space: pre-wrap; background: white; padding: 10px; border: 1px solid #ddd; border-radius: 4px; margin-top: 5px;">
                                ${escapeHtml(secret.notes)}
                            </div>
                        </div>
                    ` : ''}
                </div>
            </div>
        `;
        
        document.getElementById('viewModal').style.display = 'block';
    } catch (error) {
        console.error('Error viewing secret:', error);
        alert('Failed to load secret details');
    }
}

// Save secret
async function saveSecret(event) {
    event.preventDefault();
    
    const data = {
        title: document.getElementById('editTitle').value.trim(),
        category: document.getElementById('editCategory').value,
        username: document.getElementById('editUsername').value.trim(),
        password: document.getElementById('editPassword').value,
        api_key: document.getElementById('editApiKey').value,
        url: document.getElementById('editUrl').value.trim(),
        notes: document.getElementById('editNotes').value.trim()
    };
    
    if (!data.title) {
        alert('Title is required');
        return;
    }
    
    const isNew = !currentEditSecret;
    const url = isNew ? API_BASE_URL : `${API_BASE_URL}/${currentEditSecret.id}`;
    const method = isNew ? 'POST' : 'PUT';
    
    try {
        const response = await authFetch(url, {
            method: method,
            body: JSON.stringify(data)
        });
        
        if (!response) return;
        
        if (response.ok) {
            alert(`Secret ${isNew ? 'added' : 'updated'} successfully!`);
            closeModal();
            loadSecrets();
        } else {
            const error = await response.json();
            throw new Error(error.error || `Failed to ${isNew ? 'add' : 'update'} secret`);
        }
    } catch (error) {
        console.error('Error saving secret:', error);
        alert(error.message);
    }
}

// Delete secret
async function deleteSecret(id) {
    if (!confirm('Are you sure you want to delete this secret? This action cannot be undone.')) return;
    
    try {
        const response = await authFetch(`${API_BASE_URL}/${id}`, {
            method: 'DELETE'
        });
        
        if (!response) return;
        
        if (response.ok) {
            alert('Secret deleted successfully!');
            loadSecrets();
        } else {
            const data = await response.json();
            throw new Error(data.error || 'Failed to delete secret');
        }
    } catch (error) {
        console.error('Error deleting secret:', error);
        alert(error.message);
    }
}

// Utility functions
function togglePassword(fieldId) {
    const field = document.getElementById(fieldId);
    field.type = field.type === 'password' ? 'text' : 'password';
}

function revealPassword(button, password) {
    const span = button.previousElementSibling;
    if (span.textContent === '••••••••') {
        span.textContent = password;
        button.textContent = 'Hide';
    } else {
        span.textContent = '••••••••';
        button.textContent = 'Show';
    }
}

function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(() => {
        alert('Copied to clipboard!');
    }).catch(err => {
        console.error('Failed to copy:', err);
        alert('Failed to copy to clipboard');
    });
}

function closeModal() {
    document.getElementById('secretModal').style.display = 'none';
    currentEditSecret = null;
}

function closeViewModal() {
    document.getElementById('viewModal').style.display = 'none';
}

function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDate(dateString) {
    if (!dateString) return '';
    const date = new Date(dateString);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
}

function logout() {
    if (confirm('Are you sure you want to log out?')) {
        localStorage.clear();
        window.location.href = '/';
    }
}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    const token = localStorage.getItem('token');
    
    if (!token) {
        redirectToLogin('Please log in to continue.');
        return;
    }
    
    // Load secrets
    loadSecrets();
    
    // Setup search
    const searchInput = document.getElementById('searchInput');
    const categoryFilter = document.getElementById('categoryFilter');
    
    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            debounceSearch(e.target.value.trim(), categoryFilter.value);
        });
    }
    
    if (categoryFilter) {
        categoryFilter.addEventListener('change', (e) => {
            loadSecrets(searchInput.value.trim(), e.target.value);
        });
    }
    
    // Close modals when clicking outside
    window.addEventListener('click', (event) => {
        if (event.target.classList.contains('modal')) {
            event.target.style.display = 'none';
        }
    });
    
    // Close modals with Escape key
    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') {
            closeModal();
            closeViewModal();
        }
    });
});