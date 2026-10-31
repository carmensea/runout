import { Navigate, Route, Routes } from 'react-router-dom';
import { AppShell } from '../components/shell/AppShell';
import { GenrePage } from '../pages/genres/GenrePage';
import { TimeMachinePage } from '../pages/time-machine/TimeMachinePage';
import { OverviewPage } from '../pages/overview/OverviewPage';
import { PendingScreen } from '../pages/PendingScreen';
import { SettingsScreen } from '../pages/settings/SettingsScreen';
import { PeriodProvider } from '../state/PeriodContext';

export function App() {
  return (
    <PeriodProvider>
      <Routes>
        <Route element={<AppShell />}>
          <Route path="/" element={<Navigate to="/overview" replace />} />
          <Route path="/overview" element={<OverviewPage />} />
          <Route path="/time-machine" element={<TimeMachinePage />} />
          <Route path="/genres/:slug" element={<GenrePage />} />
          <Route path="/artists" element={<PendingScreen eyebrow="03 / Artists" title="Artists" description="Every artist in your history, ranked for the selected period." />} />
          <Route path="/artists/:artistId" element={<PendingScreen eyebrow="03 / Artists" title="Artist" description="Listening history for one artist: monthly scrobbles, rotation periods and first scrobble." />} />
          <Route path="/albums/:albumId" element={<PendingScreen eyebrow="03 / Artists" title="Album" description="Listening history for one album." />} />
          <Route path="/tracks" element={<PendingScreen eyebrow="04 / Tracks" title="Tracks" description="Every track in your history, ranked for the selected period." />} />
          <Route path="/tracks/:trackId" element={<PendingScreen eyebrow="04 / Tracks" title="Track" description="Play frequency for one track, with replay periods marked." />} />
          <Route path="/lyrics" element={<PendingScreen eyebrow="05 / Lyrics" title="Lyrics" planned description="Lyrics search across songs in your own history, with excerpts only where a licensed provider allows them." />} />
          <Route path="/mood" element={<PendingScreen eyebrow="06 / Mood" title="Mood" planned description="How the music you played shifts over time, from fixed and visible tag lists. It describes the music, not you." />} />
          <Route path="/settings" element={<SettingsScreen />} />
          <Route path="/connect" element={<PendingScreen eyebrow="Onboarding" title="Connect Last.fm" description="Check your Last.fm username, confirm your timezone and approve read access to your scrobbles." />} />
          <Route path="*" element={<PendingScreen eyebrow="Not found" title="Page not found" description="There is no page at this address." />} />
        </Route>
      </Routes>
    </PeriodProvider>
  );
}
