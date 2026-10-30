import { notFound, redirect } from 'next/navigation';

// No home page: each promotion has its own address. HUB_HOME_SLUG can point the bare domain at one (useful in a sandbox).
export default function Home() {
  if (process.env.HUB_HOME_SLUG) redirect(`/${process.env.HUB_HOME_SLUG}`);
  notFound();
}
