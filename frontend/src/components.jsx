import { CLASSIFICATIONS } from './lib.js';

const ICONS = {
  shield: <><path d="M12 3 4.5 6v5.5c0 4.6 3.1 7.9 7.5 9.5 4.4-1.6 7.5-4.9 7.5-9.5V6L12 3Z" /><path d="M9 15h6M9 11.5h6" /></>,
  overview: <><path d="M4 18 9 6l5 8 2-3 4 7" /></>,
  data: <><ellipse cx="12" cy="5.5" rx="7.5" ry="2.5" /><path d="M4.5 5.5v13c0 1.4 3.4 2.5 7.5 2.5s7.5-1.1 7.5-2.5v-13M4.5 12c0 1.4 3.4 2.5 7.5 2.5s7.5-1.1 7.5-2.5" /></>,
  approvals: <><circle cx="12" cy="12" r="8.5" /><path d="m8.5 12.2 2.4 2.4 4.6-5" /></>,
  ask: <><path d="M20 12a8 8 0 0 1-11.6 7.1L4 20l.9-4.4A8 8 0 1 1 20 12Z" /></>,
};

export function Icon({ name }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {ICONS[name]}
    </svg>
  );
}

export function ClassPill({ value }) {
  const known = CLASSIFICATIONS.find((c) => c.key === value);
  return <span className={`zt-class zt-class--${value}`}>{known ? known.label : value}</span>;
}

export function Footer() {
  return (
    <footer className="zt-footer" aria-label="Site footer">
      <div className="zt-footer__rail" aria-hidden="true" />
      <p className="zt-footer__tagline"><em>Start with the password in the code. Finish with nothing worth stealing.</em></p>
      <div className="zt-footer__bottom">
        <span>© {new Date().getFullYear()} Raymon Epping</span>
        <span className="zt-footer__links">
          <a href="https://github.com/raymonepping" target="_blank" rel="noopener noreferrer">GitHub</a>
          <a href="https://x.com/doctor_nosql" target="_blank" rel="noopener noreferrer">X</a>
          <a href="https://linkedin.com/in/raymonepping" target="_blank" rel="noopener noreferrer">LinkedIn</a>
          <a href="https://medium.com/@raymonepping" target="_blank" rel="noopener noreferrer">Medium</a>
        </span>
      </div>
    </footer>
  );
}
