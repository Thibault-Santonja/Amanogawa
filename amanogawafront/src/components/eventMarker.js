import React from "react";
import {Marker, Popup} from "react-leaflet";
import {getGeopointData} from "../utils/geoTools";
import {convertDatabase2Date} from "../utils/dateTools";

export default function EventMarker(props) {
    let event = props.event;

    const eventData = {
        begin: event.begin,
        end: event.end,
        geolocation: getGeopointData(event.geolocation),
        name: event.name,
        description: event.description,
        descriptionFull: event.extract,
        wiki_link: event.wiki_link
    };

    // fixme
    let desc_full = eventData.descriptionFull;
    if (eventData.descriptionFull && eventData.descriptionFull.length > 255) {
        desc_full = eventData.descriptionFull.substring(0, 250) + ' [...]'
    }
    
    // Render
    return (
        <Marker position={[eventData.geolocation.latitude, eventData.geolocation.longitude]}>
            <Popup>
                <h3>{eventData.name}</h3>
                <p>{convertDatabase2Date(eventData.begin)} - {convertDatabase2Date(eventData.end)}</p>

                <br/><h5>Description</h5>
                <p>{eventData.description}</p>

                <br/><h5>Extract</h5>
                <p>{desc_full /*eventData.descriptionFull.substring(0,255)*/}</p>

                <br/><h5><a href={eventData.wiki_link}>See more !</a></h5>
            </Popup>
        </Marker>
    );

}