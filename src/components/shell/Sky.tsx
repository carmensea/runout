import { useTheme } from '../../theme/useTheme';
import styles from './Sky.module.css';

/**
 * The moving sky behind Cotton Candy and Midnight Candy: idlewinny.com's rotating background
 * (components/rotating-background.tsx and starry-background.tsx in the recovered site), kept as
 * written except that the 50 ms timer is a CSS rotation of the same period, and the stars are a
 * fixed, seeded set rather than 150 random ones. Colours, blur, overlay and turn come from the
 * theme's tokens (src/styles/tokens.css). Nothing renders in Original and Moss.
 *
 * Prototype knobs on <html>, read once: data-sky-turn (seconds), data-sky-stars (count),
 * data-sky-mode ("faithful" draws the blurred layer at 200% like the original; the default draws
 * it at 100% and scales it, which looks the same and costs a quarter of the pixels).
 */
export function Sky() {
  const [theme] = useTheme();
  if (theme !== 'cotton-candy' && theme !== 'midnight-candy') return null;
  const knobs = document.documentElement.dataset;
  const turn = knobs.skyTurn ? `${Number(knobs.skyTurn)}s` : undefined;
  const count = knobs.skyStars === undefined ? 40 : Number(knobs.skyStars);
  const faithful = knobs.skyMode === 'faithful';
  return (
    <div className={styles.sky} aria-hidden="true" data-testid="sky">
      <div className={faithful ? styles.gradientFaithful : styles.gradient} style={turn ? { animationDuration: turn } : undefined} />
      <div className={styles.overlay} />
      {count > 0 && (
        <div className={styles.stars}>
          {stars(count).map((s) => (
            <i
              key={s.id}
              className={styles.star}
              style={{ left: `${s.x}%`, top: `${s.y}%`, width: s.size, height: s.size, background: s.color, opacity: s.opacity, animationDuration: `${s.twinkle}s`, animationDelay: `${s.delay}s` }}
            />
          ))}
        </div>
      )}
    </div>
  );
}

// The original's star colours and ranges, placed by a fixed seed so the sky is the same on every visit.
const COLORS = ['rgb(255, 255, 255)', 'rgb(255, 255, 240)', 'rgb(240, 240, 255)', 'rgb(255, 245, 220)', 'rgb(220, 240, 255)'];

function stars(count: number) {
  let seed = 20250325;
  const rand = () => {
    seed = (seed * 1664525 + 1013904223) % 4294967296;
    return seed / 4294967296;
  };
  return Array.from({ length: count }, (_, id) => ({
    id,
    x: rand() * 100,
    y: rand() * 100,
    size: rand() * 2.5 + 0.5,
    opacity: rand() * 0.6 + 0.4,
    twinkle: rand() * 3 + 1,
    color: COLORS[Math.floor(rand() * COLORS.length)]!,
    delay: rand() * 2,
  }));
}
