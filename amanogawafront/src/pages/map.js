import React, { useEffect, useState } from 'react';
import '../App.css';
import Events from '../components/events';
import withListLoading from '../components/withListLoading';
import axios from "axios";


function App() {
    const [appState, setAppState] = useState({
        loading: false,
        repos: null,
    });

    useEffect(() => {
        setAppState({ loading: true });

        axios
            .get('/events/')
            .then((res)=>{
                console.log(res.data);
                setAppState({ loading: false, repos: res.data });
            })
            .catch(error => {
                console.error(error);
            });
    });

    return (
        <div className='App'>
            <div className='container'>
                <h1>Amanogawa Map</h1>
            </div>
            <div className='map-container'>
                {appState.loading ? (
                        <withListLoading />
                    ) : (
                        <Events
                            event={appState.repos}
                        />
                    ) }
            </div>
        </div>
    );
}
export default App;
