import React, { useEffect, useState } from 'react';
import { MapContainer, TileLayer, Marker, Popup } from 'react-leaflet'
import axios from "axios";
import '../App.css';
import withListLoading from '../components/withListLoading';
import {getGeopointData} from '../utils/geoTools'
import {convertDatabase2Date, convertDate2Database} from '../utils/dateTools';

import TimelineSlider from '../components/timelineRange'
const startTime     = -4000; //-4000; aie aie aie pas de dates négatives.............
const endTime       = new Date().getFullYear();
const stepNumber    = 20;


const EventMarker = (props) => {
    let events = props.events;

    return events.map((entry, index) => {
        const {begin, end, geolocation, name, description, wiki_link} = entry;
        let coord = getGeopointData(geolocation)

        return (
            <Marker position={[coord.latitude, coord.longitude]}>
                <Popup>
                    <h3>{name}</h3>
                    <p>{convertDatabase2Date(begin)} - {convertDatabase2Date(end)}</p>
                    <p>{description}</p>
                    {wiki_link? (<a href={wiki_link}>Wiki link</a>) : (<p>No link...</p>)}
                </Popup>
            </Marker>
        )
    })
}


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
    }, []);

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
        console.log(appState.repos)
    }

    // Render
    return (
        <div className='map-container'>
            {appState.loading ? (
                <withListLoading />
            ) : (
                <>
                    <MapContainer center={[48.215863, 16.391984]} zoom={5} scrollWheelZoom={false}>
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
                        <EventMarker events={appState.repos} />
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
