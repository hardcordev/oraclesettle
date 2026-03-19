/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        'os-bg':        '#0B0F1A',
        'os-card':      '#111827',
        'os-border':    '#1F2D45',
        'os-yes':       '#22C55E',
        'os-no':        '#EF4444',
        'os-blue':      '#3B82F6',
        'os-text':      '#94A3B8',
        'os-yes-dim':   '#052E16',
        'os-no-dim':    '#2B0A0A',
        'os-blue-dim':  '#0C1A3A',
      },
      fontFamily: {
        sans: ['Inter', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'monospace'],
      },
      animation: {
        'pulse-green': 'pulse-green 2s ease-in-out infinite',
        'pulse-dot':   'pulse-dot 2s ease-in-out infinite',
        'spin-slow':   'spin 3s linear infinite',
      },
      keyframes: {
        'pulse-green': {
          '0%, 100%': { boxShadow: '0 0 0 0 rgba(34, 197, 94, 0.4)' },
          '50%':       { boxShadow: '0 0 0 8px rgba(34, 197, 94, 0)' },
        },
        'pulse-dot': {
          '0%, 100%': { opacity: '1' },
          '50%':       { opacity: '0.3' },
        },
      },
    },
  },
  plugins: [],
}
