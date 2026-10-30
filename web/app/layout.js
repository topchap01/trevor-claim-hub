import './globals.css';

export const metadata = {
  title: 'Claim Hub (test)',
  description: 'Cashback claims',
  robots: { index: false, follow: false },
};

export const viewport = { width: 'device-width', initialScale: 1, themeColor: '#041E50' };

export default function RootLayout({ children }) {
  return (
    <html lang="en-AU">
      <body>
        <div className="testbar">Sandbox test. Made-up promotion, no real money is paid.</div>
        {children}
      </body>
    </html>
  );
}
