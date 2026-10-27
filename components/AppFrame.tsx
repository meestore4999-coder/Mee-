'use client';
import {usePathname} from 'next/navigation';
import {MEEProvider} from '../lib/mee-context';
import Shell from './Shell';
import AuthGate from './AuthGate';
export default function AppFrame({children}:{children:React.ReactNode}){const path=usePathname();const isPublicStore=path.startsWith('/store/');return <MEEProvider>{isPublicStore?children:<><AuthGate/><Shell>{children}</Shell></>}</MEEProvider>}
