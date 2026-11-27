'use client';
import {usePathname} from 'next/navigation';
import {MEEProvider,useMEE} from '../lib/mee-context';
import Shell from './Shell';
import AuthGate from './AuthGate';

function AppFrameContent({children}:{children:React.ReactNode}){
 const path=usePathname();
 const {ready,configured,session,businessId}=useMEE();
 const isPublicStore=path.startsWith('/store/');
 if(isPublicStore)return <>{children}</>;
 if(!ready)return <div className="auth-screen"><div className="auth-card">MEE load ho raha hai…</div></div>;
 // Render the login/setup screen exclusively until authentication and business setup finish.
 // This prevents the protected application shell from competing with or covering AuthGate.
 if(!configured||!session||!businessId)return <AuthGate/>;
 return <Shell>{children}</Shell>;
}

export default function AppFrame({children}:{children:React.ReactNode}){
 return <MEEProvider><AppFrameContent>{children}</AppFrameContent></MEEProvider>;
}
