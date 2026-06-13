
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
// PR-D: self-hosted stylesheets (were cdnjs/Google Fonts CDN links in index.html).
// Imported before ./index.css so the app's local rules (e.g. .markdown-body) win.
import '@fortawesome/fontawesome-free/css/all.min.css';
import 'github-markdown-css/github-markdown-light.css';
import '@fontsource/inter/300.css';
import '@fontsource/inter/400.css';
import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import '@fontsource/inter/700.css';
import './index.css';
import './i18n';

// Error Boundary — catches React render crashes and shows the error instead of white screen
class ErrorBoundary extends React.Component<{ children: React.ReactNode }, { error: Error | null }> {
  constructor(props: { children: React.ReactNode }) {
    super(props);
    this.state = { error: null };
  }
  static getDerivedStateFromError(error: Error) {
    return { error };
  }
  componentDidCatch(error: Error, info: React.ErrorInfo) {
    console.error('[ErrorBoundary] React crashed:', error, info.componentStack);
  }
  render() {
    if (this.state.error) {
      return (
        <div style={{ padding: '40px', fontFamily: 'monospace', background: '#1a1a1a', color: '#ff6b6b', minHeight: '100vh' }}>
          <h1 style={{ fontSize: '24px', marginBottom: '16px' }}>⚠️ SoloLedger crashed</h1>
          <pre style={{ whiteSpace: 'pre-wrap', fontSize: '14px', color: '#ffa07a', background: '#2a2a2a', padding: '16px', borderRadius: '8px', overflow: 'auto' }}>
            {this.state.error.message}
            {'\n\n'}
            {this.state.error.stack}
          </pre>
          <button onClick={() => { this.setState({ error: null }); window.location.reload(); }}
            style={{ marginTop: '16px', padding: '8px 16px', background: '#274C92', color: 'white', border: 'none', borderRadius: '8px', cursor: 'pointer' }}>
            Reload
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

const rootElement = document.getElementById('root');
if (!rootElement) {
  throw new Error("Could not find root element to mount to");
}

const root = ReactDOM.createRoot(rootElement);
root.render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
);
