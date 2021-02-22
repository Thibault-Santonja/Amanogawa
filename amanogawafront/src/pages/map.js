import React, { useEffect, useState } from 'react';
import { MapContainer, TileLayer, Polygon } from 'react-leaflet'
import axios from "axios";
import '../App.css';
import withListLoading from '../components/withListLoading';
import TimelineSlider from '../components/timelineRange'
import EventMarker from '../components/eventMarker'

const startTime     = -4000;
const endTime       = new Date().getFullYear();
const stepNumber    = 20;


function Map() {
    const [appState, setAppState] = useState({
        loading: false,
        repos: [],
    });
    const [dates, setDates] = useState({
        start: startTime,
        end: endTime
    });

    // Effect
    useEffect(() => {
        setAppState({ loading: true });

        fetchData();

        // fixme : React Hook useEffect has a missing dependency: 'fetchData'. Either include it or remove the
        //  dependency array  react-hooks/exhaustive-deps
        //  eslint-disable-next-line
    }, [] /*propriétés à surveiller / watcher*/);

    // Data
    function handleTimelineRangeComponentDates(date) {
        setDates({
            start:  date[0],
            end:    date[1]
        });

        fetchData();
    }

    function fetchData() {
        axios
            .get('/events/', {params: {start: dates.start+4000, end: dates.end+4001}})
            .then((res)=>{
                console.log(res.data);
                setAppState({ loading: false, repos: res.data });
            })
            .catch(error => {
                console.error(error);
            });
    }

    // Render [48.215863, 16.391984]
    return (
        <div className='map-container'>
            {appState.loading ? (
                <withListLoading />
            ) : (
                <>
                    <MapContainer center={[30, 65]} zoom={4} scrollWheelZoom={true}>
                        <link
                            rel="stylesheet"
                            href="https://unpkg.com/leaflet@1.6.0/dist/leaflet.css"
                            integrity="sha512-xwE/Az9zrjBIphAcBb3F6JVqxf46+CDLwfLMHloNu6KEQCAWi6HcDUbeOfBIptF7tcCzusKFjFw2yuvEpDL9wQ=="
                            crossOrigin=""
                        />
                        <TileLayer
                            attribution='&copy; <a href="http://osm.org/copyright">OpenStreetMap</a> contributors'
                            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                        />
                        {appState.repos.map((entry, index) => <EventMarker event={entry} />)}
                        <Polygon positions={[[42.3,3.5], [43.6, 7.7], [49.0, 8.2], [51.2, 2.4], [48.5, -4.9], [43.3, -1.9]]}/>
                    </MapContainer>


                    <div className="d-flex justify-content-center fixed-bottom"  style={{backgroundColor: 'rgba(250,252,255,0.8)'}} >
                        <div className="w-75">
                            <TimelineSlider startTime={startTime} endTime={endTime} stepNumber={stepNumber} handleChange={handleTimelineRangeComponentDates}/>
                        </div>
                    </div>
                </>
            ) }
        </div>
    );
}
export default Map;
