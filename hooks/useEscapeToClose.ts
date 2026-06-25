import { useEffect } from 'react';

/**
 * Close a modal / overlay when the Escape key is pressed.
 *
 * - `enabled` gates activation (e.g. `modalOpen && !saving`) so the listener is
 *   only attached while the dialog should actually respond to Escape, and is
 *   removed during a save/submit so the dialog cannot be dismissed mid-flight.
 * - IME composition is ignored (`e.isComposing` / `keyCode === 229`): pressing
 *   Escape to cancel a CJK input candidate must NOT close the dialog.
 *
 * Intentionally minimal: no focus management, no topmost/stopPropagation
 * registry. Only use on standalone, non-nested dialogs (see C6-2 scope).
 */
export function useEscapeToClose(enabled: boolean, onClose: () => void): void {
  useEffect(() => {
    if (!enabled) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      if (e.isComposing || e.keyCode === 229) return; // ignore IME composition
      onClose();
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [enabled, onClose]);
}
