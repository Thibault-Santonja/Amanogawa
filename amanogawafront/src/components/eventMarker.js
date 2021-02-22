import React from "react";
import {Marker, Popup} from "react-leaflet";
import {getGeopointData} from "../utils/geoTools";
import {convertDatabase2Date} from "../utils/dateTools";

const color1 = [0,0,50];  // 0A946B
const color2 = [80, 18, 79]; // 0B1994

function getWeight(fullDate) {return fullDate.substring(0, 4) / (new Date().getFullYear() + 1)}

function pickHex(color1, color2, weight) {
    let w = weight * 2 - 1;
    let w1 = (w + 1) / 2;
    let w2 = 1 - w1;
    return 'rgba(' + Math.round(color1[0] * w1 + color2[0] * w2) + ', ' +
        Math.round(color1[1] * w1 + color2[1] * w2) + ', ' +
        Math.round(color1[2] * w1 + color2[2] * w2) + ', 0.9)';
}

export default function EventMarker(props) {
    let event = props.event;

    const eventData = {
        begin: event.begin,
        end: event.end,
        geolocation: getGeopointData(event.geolocation),
        name: event.name,
        description: event.description,
        descriptionFull: event.extract,
        wiki_link: event.wiki_link,
        color: pickHex(color1, color2, getWeight(event.begin))
    };

    // fixme
    let desc_full = eventData.descriptionFull;
    if (eventData.descriptionFull && eventData.descriptionFull.length > 255) {
        desc_full = eventData.descriptionFull.substring(0, 250) + ' [...]'
    }

    // Render
    return (
        <Marker pathOptions={{color: eventData.color}} position={[eventData.geolocation.latitude, eventData.geolocation.longitude]}
            >
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