function getGeopointData(geopoint) {
    let srid = geopoint.split(';')[0].split('=')[1];
    let lat = geopoint.split(';')[1].replace('POINT (', '').replace(')', '').split(' ')[1];
    let lon = geopoint.split(';')[1].replace('POINT (', '').replace(')', '').split(' ')[0];

    return {'longitude':parseFloat(lon), 'latitude':parseFloat(lat), 'srid':srid};
}

export {getGeopointData}