/** Material Symbols Sharp, weight 300 (HANDOFF.md "Typography"). Decorative unless labelled by its control. */
export function Icon({ name, size = 18, className }: { name: string; size?: number; className?: string }) {
  return (
    <span className={className ? `icon ${className}` : 'icon'} style={{ fontSize: size }} aria-hidden="true">
      {name}
    </span>
  );
}
