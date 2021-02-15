function pad(num, size) {
    let negative = new Boolean(false);

    if (num < 0) {negative = true}

    num = num.toString();

    if (negative) {
        while (num.length < size+1) num = [num.slice(0, 1), "0", num.slice(1)].join('');
    } else {
        while (num.length < size) num = "0" + num;
    }

    return num;
}

function convertDatabase2Date(date) {
    //return pad(parseInt(date.slice(0, 4))-4000, 4) + date.slice(4);
    return (parseInt(date.slice(0, 4)) - 4000).toString() + date.slice(4);
}

function convertDate2Database(date) {
    return (parseInt(date.slice(0, 4)) + 4000).toString() + date.slice(4);
}

export {convertDatabase2Date, convertDate2Database}