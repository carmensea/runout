import { render } from '@testing-library/react';
import { useEffect } from 'react';
import { MemoryRouter, useLocation } from 'react-router-dom';
import { App } from '../app/App';
import type { RunoutApi } from '../data/api';
import { AppDataProvider } from '../data/AppDataContext';

export const location = { current: '' };

function LocationProbe() {
  const l = useLocation();
  useEffect(() => {
    location.current = `${l.pathname}${l.search}`;
  }, [l]);
  return null;
}

export function renderApp(api: RunoutApi, url = '/overview?period=all') {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <AppDataProvider api={api}>
        <App />
        <LocationProbe />
      </AppDataProvider>
    </MemoryRouter>,
  );
}
