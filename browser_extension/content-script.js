// EasyPass Browser Extension - Content Script
// Detects login forms and handles auto-fill

// ─── Form Detection ───────────────────────────────────────

function findLoginForms() {
  const forms = [];
  
  // Find all forms on the page
  document.querySelectorAll('form').forEach(form => {
    const inputs = form.querySelectorAll('input');
    const hasPassword = Array.from(inputs).some(input => 
      input.type === 'password' || input.autocomplete === 'current-password'
    );
    
    if (hasPassword) {
      forms.push({
        formElement: form,
        inputs: Array.from(inputs).map(input => ({
          element: input,
          type: input.type,
          name: input.name,
          id: input.id,
          autocomplete: input.autocomplete,
          placeholder: input.placeholder ? input.placeholder.toLowerCase() : '',
        }))
      });
    }
  });
  
  // Also find password fields not in forms (SPA-style)
  const allPasswordInputs = document.querySelectorAll('input[type="password"]');
  allPasswordInputs.forEach(pwInput => {
    // Check if already captured in a form
    const alreadyFound = forms.some(form => 
      form.inputs.some(i => i.element === pwInput)
    );
    
    if (!alreadyFound) {
      // Find the nearest form or container
      const container = pwInput.closest('form') || pwInput.parentElement;
      const inputs = container ? container.querySelectorAll('input') : [pwInput];
      
      forms.push({
        formElement: container || pwInput,
        inputs: Array.from(inputs).map(input => ({
          element: input,
          type: input.type,
          name: input.name,
          id: input.id,
          autocomplete: input.autocomplete,
          placeholder: input.placeholder ? input.placeholder.toLowerCase() : '',
        }))
      });
    }
  });
  
  return forms;
}

// ─── Identify Field Type ──────────────────────────────────

function identifyField(input) {
  const attrs = (input.name + ' ' + input.id + ' ' + input.autocomplete + ' ' + input.placeholder).toLowerCase();
  
  if (input.type === 'password' || attrs.includes('password') || attrs.includes('passwd') || attrs.includes('current-password')) {
    return 'password';
  }
  
  if (attrs.includes('username') || attrs.includes('login') || attrs.includes('email') || 
      attrs.includes('user') || attrs.includes('account') || input.type === 'email') {
    return 'username';
  }
  
  if (attrs.includes('totp') || attrs.includes('2fa') || attrs.includes('mfa') || 
      attrs.includes('code') || attrs.includes('token') || attrs.includes('authenticator')) {
    return 'totp';
  }
  
  return null;
}

// ─── Auto-fill Form ───────────────────────────────────────

function fillForm(credentials) {
  const forms = findLoginForms();
  
  forms.forEach(form => {
    let usernameField = null;
    let passwordField = null;
    let totpField = null;
    
    form.inputs.forEach(input => {
      const type = identifyField(input);
      if (type === 'username' && !usernameField) usernameField = input.element;
      if (type === 'password' && !passwordField) passwordField = input.element;
      if (type === 'totp' && !totpField) totpField = input.element;
    });
    
    // Fill username
    if (usernameField && credentials.username) {
      setNativeValue(usernameField, credentials.username);
      usernameField.dispatchEvent(new Event('input', { bubbles: true }));
      usernameField.dispatchEvent(new Event('change', { bubbles: true }));
    }
    
    // Fill password
    if (passwordField && credentials.password) {
      setNativeValue(passwordField, credentials.password);
      passwordField.dispatchEvent(new Event('input', { bubbles: true }));
      passwordField.dispatchEvent(new Event('change', { bubbles: true }));
    }
    
    // Fill TOTP if available
    if (totpField && credentials.totp) {
      setNativeValue(totpField, credentials.totp);
      totpField.dispatchEvent(new Event('input', { bubbles: true }));
    }
  });
}

// ─── Helper: Set value in React/Angular/Vue friendly way ──

function setNativeValue(element, value) {
  const nativeInputValueSetter = Object.getOwnPropertyDescriptor(
    window.HTMLInputElement.prototype, 'value'
  ).set;
  nativeInputValueSetter.call(element, value);
}

// ─── Add EasyPass Icon to Password Fields ─────────────────

function addEasyPassIconToFields() {
  const forms = findLoginForms();
  
  forms.forEach(form => {
    form.inputs.forEach(input => {
      if (identifyField(input) === 'password' && input.element.dataset.easypassIcon !== 'true') {
        input.element.dataset.easypassIcon = 'true';
        input.element.style.position = 'relative';
        
        const icon = document.createElement('div');
        icon.className = 'easypass-icon';
        icon.innerHTML = '🔒';
        icon.style.cssText = `
          position: absolute;
          right: 8px;
          top: 50%;
          transform: translateY(-50%);
          cursor: pointer;
          font-size: 16px;
          z-index: 9999;
          opacity: 0.7;
        `;
        icon.title = 'Fill with EasyPass';
        
        icon.addEventListener('click', (e) => {
          e.preventDefault();
          e.stopPropagation();
          
          chrome.runtime.sendMessage({
            action: 'getCredentials',
            url: window.location.href
          }, (response) => {
            if (response && !response.error) {
              fillForm(response);
            }
          });
        });
        
        // Wrap input in a container if not already
        const parent = input.element.parentElement;
        if (parent && getComputedStyle(parent).position === 'static') {
          parent.style.position = 'relative';
        }
        parent.appendChild(icon);
      }
    });
  });
}

// ─── Listen for Messages from Popup/Background ────────────

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'fillCredentials') {
    fillForm(request.credentials);
    sendResponse({ success: true });
  } else if (request.action === 'detectForms') {
    const forms = findLoginForms();
    const currentUrl = window.location.href;
    sendResponse({ forms: forms.length, url: currentUrl });
  }
  return true;
});

// ─── Initialize ───────────────────────────────────────────

// Run on page load
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', addEasyPassIconToFields);
} else {
  addEasyPassIconToFields();
}

// Watch for dynamically added forms (SPAs)
const observer = new MutationObserver((mutations) => {
  let shouldCheck = false;
  mutations.forEach(mutation => {
    if (mutation.addedNodes.length > 0) shouldCheck = true;
  });
  if (shouldCheck) {
    setTimeout(addEasyPassIconToFields, 500);
  }
});

observer.observe(document.body, {
  childList: true,
  subtree: true
});

console.log('EasyPass content script loaded');