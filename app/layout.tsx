import './globals.css';
import AppFrame from '../components/AppFrame';
export const metadata={title:'MEE | Multi-Store Billing & Inventory',description:'MEE live multi-store business management'};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="en"><body><AppFrame>{children}</AppFrame></body></html>}
