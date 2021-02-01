import React, { useEffect, useState } from 'react';
import '../App.css';
import Events from '../components/showEvents';
import withListLoading from '../components/withListLoading';
import axios from "axios";
import { MapContainer, TileLayer, Marker, Popup } from 'react-leaflet'


const EventMarker = (props) => {
    let events = props.events;

    function getGeopointData(geopoint) {
        let srid = geopoint.split(';')[0].split('=')[1];
        let lat = geopoint.split(';')[1].replace('POINT (', '').replace(')', '').split(' ')[1];
        let lon = geopoint.split(';')[1].replace('POINT (', '').replace(')', '').split(' ')[0];

        return {'longitude':lon, 'latitude':lat, 'srid':srid};
    }

    return events.map((entry, index) => {
        const {begin, end, geolocation, name, description, wiki_link} = entry;
        let coord = getGeopointData(geolocation)

        return (
            <Marker position={[coord.latitude, coord.longitude]}>
                <Popup>
                    <h3>{name}</h3>
                    <p>{begin} - {end}</p>
                    <p>{description}</p>
                    <a href={wiki_link}>link</a>
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

    // Effect
    useEffect(() => {
        setAppState({ loading: true });

        fetchData();
    }, []);

    // Data
    function fetchData() {
        axios
            .get('/events/')
            .then((res)=>{
                console.log(res.data);
                setAppState({ loading: false, repos: res.data });
            })
            .catch(error => {
                console.error(error);
            });
    }

    // Render
    return (
        <div className='map-container'>
            {appState.loading ? (
                <withListLoading />
            ) : (
                <MapContainer center={[51.505, -0.09]} zoom={13} scrollWheelZoom={false}>
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
                    <Marker position={[51.505, -0.09]}>
                        <Popup>
                            A pretty CSS3 popup. <br /> Easily customizable.
                        </Popup>
                    </Marker>
                    <EventMarker events={appState.repos} />
                </MapContainer>
            ) }
        </div>
    );
}
export default Map;
