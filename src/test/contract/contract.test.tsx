import { screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import type { OverviewData } from '../../data/types';
import { connectedApi } from '../fixtures';
import { renderApp } from '../renderApp';
import overview2014 from './overview-2014.json';

/**
 * The shared contract example: exactly what the backend computes for a fixed synthetic history
 * (server/test/contract/overview_contract_test.rb), rendered by the real Overview page.
 */
const data = overview2014 as unknown as OverviewData;

describe('the backend’s Overview, rendered', () => {
  it('shows its figures, lists and states without adaptation', async () => {
    renderApp(connectedApi(() => data), '/overview?period=year:2014');
    expect(await screen.findByText(data.stats.scrobbles.toLocaleString('en-GB'))).toBeInTheDocument();
    expect(screen.getByText(/Part of this period isn’t imported: 2014-11-01 to 2014-12-31/)).toBeInTheDocument();
    expect(screen.getByText(/Genres aren’t available yet/)).toBeInTheDocument();
    expect(screen.getByText(/Artist metadata isn’t available yet/)).toBeInTheDocument();

    const top = screen.getByRole('region', { name: /Who you played most/ });
    for (const artist of data.top.artists.slice(0, 3)) expect(within(top).getAllByText(artist.name).length).toBeGreaterThan(0);
    expect(within(top).getByText('Not Matched Yet')).toBeInTheDocument();
    for (const r of data.onRepeat) expect(screen.getAllByText(r.name).length).toBeGreaterThan(0);
    for (const r of data.discovery.rediscovered) expect(screen.getAllByText(r.name).length).toBeGreaterThan(0);
  });
});
