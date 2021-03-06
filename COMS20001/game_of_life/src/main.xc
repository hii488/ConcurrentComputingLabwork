// COMS20001 - Cellular Automaton Farm - Initial Code Skeleton
// (using the XMOS i2c accelerometer demo code)

#include <platform.h>
#include <xs1.h>
#include <stdio.h>
#include "pgmIO.h"
#include "i2c.h"

#define  IMHT 16                   						  //image height
#define  IMWD 16                  						  //image width
#define  CIMWD IMWD/8              						  //compressed image width
#define  PTHT (IMHT % 11 != 0 ? IMHT/11 + 1 : IMHT/11)    //image part height - NB: IMHT/PTHT <= 11
#define  PTNM (IMHT/PTHT)  								  //number of image parts


char infname[] = "test.pgm";      // input image path
char outfname[] = "16out.pgm";    // output image path

typedef unsigned char uchar;      //using uchar as shorthand

on tile[0] : port p_scl = XS1_PORT_1E;         //interface ports to orientation
on tile[0] : port p_sda = XS1_PORT_1F;

on tile[0] : in port buttons = XS1_PORT_4E; //port to access xCore-200 buttons
on tile[0] : out port leds = XS1_PORT_4F;   //port to access xCore-200 LEDs

#define FXOS8700EQ_I2C_ADDR 0x1E  //register addresses for orientation
#define FXOS8700EQ_XYZ_DATA_CFG_REG 0x0E
#define FXOS8700EQ_CTRL_REG_1 0x2A
#define FXOS8700EQ_DR_STATUS 0x0
#define FXOS8700EQ_OUT_X_MSB 0x1
#define FXOS8700EQ_OUT_X_LSB 0x2
#define FXOS8700EQ_OUT_Y_MSB 0x3
#define FXOS8700EQ_OUT_Y_LSB 0x4
#define FXOS8700EQ_OUT_Z_MSB 0x5
#define FXOS8700EQ_OUT_Z_LSB 0x6

/////////////////////////////////////////////////////////////////////////////////////////
//
// Wait for 'n' processor cycles, where each cycle takes ten nano seconds
//
/////////////////////////////////////////////////////////////////////////////////////////
void waitMoment(int tenNano) {
    timer tmr;
    int waitTime;
    tmr :> waitTime;                       //read current timer value
    waitTime += tenNano;                   //set waitTime to 0.4s after value
    tmr when timerafter(waitTime) :> void; //wait until waitTime is reached
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Read Image from PGM file from path infname[] to channel c_out
//
/////////////////////////////////////////////////////////////////////////////////////////
void dataInStream(char infname[], chanend toDistributor){
    int res;
    uchar line[ IMWD ];
    printf("DataInStream: Start...\n");

    //Open PGM file
    res = _openinpgm( infname, IMWD, IMHT );
    if( res ) {
        printf( "DataInStream: Error opening %s\n", infname );
        return;
    }

    //Read image line-by-line and send byte by byte to channel c_out
    for( int y = 0; y < IMHT; y++ ) {
        _readinline( line, IMWD );
        for( int x = 0; x < IMWD; x++ ) {
            toDistributor <: line[ x ];
        }
    }

    //Close PGM image file
    _closeinpgm();

    printf( "DataInStream: Done...\n" );
    return;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Write pixel stream from channel c_in to PGM image file
//
/////////////////////////////////////////////////////////////////////////////////////////
void dataOutStream(char outfname[], chanend c_in){
    int res;
    uchar line[ IMWD ];

    c_in :> int; // Tell it to open the file ready for exporting.

    //Open PGM file
    printf( "DataOutStream: Start...\n" );
    res = _openoutpgm( outfname, IMWD, IMHT );

    if( res ) {
        printf( "DataOutStream: Error opening %s\n", outfname );fflush(stdout);
        return;
    }

    //Compile ea ch line of the image and write the image line-by-line
    for( int y = 0; y < IMHT; y++ ) {
        for( int x = 0; x < IMWD; x++ ) {
            c_in :> line[ x ];
        }
        _writeoutline( line, IMWD );
    }

    //Close the PGM image
    _closeoutpgm();
    printf( "DataOutStream: Done...\n" );

    return;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// The implementation of rules of Game of Life
//
/////////////////////////////////////////////////////////////////////////////////////////
int isAliveNextRound(int i[9]){
    int middleAlive = i[4];
    int amountAlive = 0;
    for(int c = 0; c < 9; c++){
        if(i[c]) amountAlive++;
    }

    int alive = 0;

    if(middleAlive) amountAlive--;

    if(middleAlive && amountAlive > 1 && amountAlive < 4) alive = 1;
    else if(!middleAlive && amountAlive == 3) alive = 1;

    return alive;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Distributor
//
/////////////////////////////////////////////////////////////////////////////////////////
void assignToWorkers(int index, uchar image[PTHT+2][CIMWD], chanend toWorker){
    for(int i = 0; i < PTHT+2; i ++) {
        for(int j = 0; j < CIMWD; j ++)
            toWorker <: image[i][j];
    }
}

void receiveFromWorkers(int index, uchar newimage[PTHT][CIMWD], chanend toWorker){
    for(int i = 0; i < PTHT; i ++) {
        for(int j = 0; j < CIMWD; j ++) {
            toWorker :> newimage[i][j];
        }
    }
}

// This function was for testing sending data to workers in a par. It is not used in the current program.
void callWorkers(int index, uchar image[PTHT+2][CIMWD], uchar newimage[PTHT][CIMWD], chanend toWorker) {
    assignToWorkers(index, image, toWorker);
    receiveFromWorkers(index, newimage, toWorker);
}

void distributor(chanend fromController, chanend toWorker[PTNM]){
    uchar image[IMHT][CIMWD], c;

    // Initialize memory for image so it's ready for bit packing
    for( int y = 0; y < IMHT; y++ ) {       //go through all lines
        for( int x = 0; x < CIMWD; x++ ) {  //go through each pixel per line
            image[y][x] = 0;
        }
    }

    //Starting up and wait for tilting of the xCore-200 Explorer
    printf( "ProcessImage: Start, size = %dx%d\n", IMHT, IMWD );
    printf( "Waiting for image...\n" );

    // Receive and bit-pack the image
    for( int y = 0; y < IMHT; y++ ) {       //go through all lines
        for( int x = 0; x < IMWD; x++ ) {   //go through each pixel per line
            fromController :> c;            //read the pixel value
            image[y][x/8] <<= 1;            //bit pack
            if(c == 255)
                image[y][x/8] ++;
        }
    }

    int process;
    int pausePrint = 0;
    while(1){
        // Ping the controller ask what to do
        fromController <: 1;
        fromController :> process;
        uchar imgPart[PTNM][PTHT+2][CIMWD], newImgPart[PTNM][PTHT][CIMWD];

        if(process == 0){ // 0: Process the image

            // Split the image into strips that can be passed to workers.
            for(int index = 0; index < PTNM; index ++) {
                for(int i = index*PTHT - 1; i <= (index+1)*PTHT; i ++) {
                    for(int j = 0; j < CIMWD; j ++)
                        imgPart[index][i - (index*PTHT - 1)][j] = image[(i+IMHT)%IMHT][j];
                }
            }

            // Pass the image strips to the workers
            for(int index = 0; index < PTNM; index ++){
                assignToWorkers(index, imgPart[index], toWorker[index]);
            }

            // Receive the updated image strips from the workers
            for(int index = 0; index < PTNM; index ++){
                receiveFromWorkers(index, newImgPart[index], toWorker[index]);
            }
//          par(int index = 0; index < PTNM; index ++){
//              callWorkers(index, imgPart[index], newImgPart[index], toWorker[index]);
//          }

            // Combine the image parts
            for( int i = 0; i < PTNM; i ++ ) {
                for( int y = 0; y < PTHT; y++ ) {
                    for( int x = 0; x < CIMWD; x++ ) {
                        if(i*PTHT + y >= IMHT)  continue;
                        image[i*PTHT + y][x] = newImgPart[i][y][x];
                    }
                }
            }
        }

        else if(process == 2){  // 2: export the 'image'
            fromController <: 0; // Give it any information to tell it we're about to export.
            for( int y = 0; y < IMHT; y++ ) {
                for( int x = 0; x < CIMWD; x++ ) {
                    for(int b = 7; b >= 0; b --) {
                        uchar c = (image[y][x]>>b & 1) * 255;
                        fromController <: c; // Send the image to dataOut
                    }
                }
            }
            // Tell the controller that we're done exporting.
            fromController <: 0;
        }

        else{ // 1 (or any undefined number): Print current image diagnostics and wait.
            if(pausePrint == 0){
                int alive = 0;
                for( int y = 0; y < IMHT; y++ ) {
                    for( int x = 0; x < CIMWD; x++ ) {
                        for(int b = 7; b >= 0; b --) {
                            if(image[y][x]>>b & 1) alive++;
                        }
                    }
                }
                printf("Alive cells: %d\n", alive);
            }
            waitMoment(25000000); // wait quarter of a second
        }
    }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Worker
//
/////////////////////////////////////////////////////////////////////////////////////////
void imgPartWorker(chanend fromDistributor) {
    uchar imgPart[PTHT+2][CIMWD], newImgPart[PTHT][CIMWD];
    while(1) {
        // Initialize the memory for result
        for(int i = 0; i < PTHT; i ++){
            for(int j = 0; j < CIMWD; j++)
                newImgPart[i][j] = 0;
        }

        // Receive from distributor
        for(int i = 0; i < PTHT+2; i ++){
            for(int j = 0; j < CIMWD; j++)
                fromDistributor :> imgPart[i][j];
        }

        // Process image
        int nearby[9];
        for(int i = 1; i <= PTHT; i ++) {
            for(int j = 0; j < CIMWD; j++){
                // For each bit in a colum pack, get the 8 bits around it
                for(int b = 7; b >= 0; b --) {
                    // At the left-most bit of each compressed colum pack
                    if(b == 7){
                        for(int ni = 0; ni < 3; ni ++) {
                            if(j == 0) // When it is the left-most of the whole image
                                // Get the right-most bit of the whole image
                                nearby[ni*3] = imgPart[i+ni-1][CIMWD-1] & 1;
                            else        // When it is the left-most of the rest packs
                                // Get the right-most bit of the previous pack
                                nearby[ni*3] = imgPart[i+ni-1][j-1] & 1;
                            for(int nj = 1; nj < 3; nj ++) {
                                nearby[ni*3+nj] = imgPart[i+ni-1][j]>>(b+1-nj) & 1;
                            }
                        }
                    }

                    // At the right-most bit of each compressed col pack, similiar logic as above
                    else if(b == 0){
                        for(int ni = 0; ni < 3; ni ++) {
                            if(j == CIMWD-1)    // When it is the right-most of the whole image
                                nearby[ni*3+2] = imgPart[i+ni-1][0]>> 7 & 1;
                            else                // When it is the right-most of the rest packs
                                nearby[ni*3+2] = imgPart[i+ni-1][j+1]>> 7 & 1;
                            for(int nj = 0; nj < 2; nj ++) {
                                nearby[ni*3+nj] = imgPart[i+ni-1][j]>>(b+1-nj) & 1;
                            }
                        }
                    }

                    // For the rest, similiar logic as above
                    else {
                        for(int ni = 0; ni < 3; ni ++) {
                            for(int nj = 0; nj < 3; nj ++) {
                                nearby[ni*3+nj] = imgPart[i+ni-1][j]>>(b+1-nj) & 1;
                            }
                        }
                    }

                    // check if the bit is alive next round and pack into the result image
                    newImgPart[i-1][j] <<= 1;
                    newImgPart[i-1][j] += isAliveNextRound(nearby);
                }
            }
        }

        // Send result to distributor
        for(int i = 0; i < PTHT; i ++)
            for(int j = 0; j < CIMWD; j++)
                fromDistributor <: newImgPart[i][j];
    }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Controller
//
/////////////////////////////////////////////////////////////////////////////////////////
void controller(chanend toDistributor, chanend fromAccelerometer, chanend fromButtonListener, chanend toleds){
    timer tmr;
    uint32_t start, end;
    long long actualTime = 0;
    int running = 0;

    while(running == 0){
        int buttonPress;
        fromButtonListener :> buttonPress;
        printf( "Controller got from button listner\n" );

        // If start button pushed...
        if(buttonPress == 14){
            toleds <: 1; // Set leds to state 1 (green on)
            dataInStream(infname, toDistributor);
            running = 1; // Set running to 1.
        }
    }

    int input;
    int paused = 0, wasPaused = 0; // 0: not paused           1: paused
    int toExport = 0;
    int rounds = 0;
    tmr :> start;
    while(1){
        select{
            case toDistributor :> input:
                switch(input){
                case 1: // Asking whether to processs
                    if(toExport == 1){
                        tmr :> end;			// Save the current time
                        actualTime += end-start;

                        toDistributor <: 2; // Export
                        toleds <: 4;        // Blue light

                        dataOutStream(outfname, toDistributor);
                        toExport = 0;
                        toleds <: 0;          // Turn off the leds
                        tmr :> start;		  // Restart the timer
                    }
                    else{
                        // If we're not paused, but we were last time, restart the timer
                        if(paused == 0 && wasPaused == 1){
                            wasPaused = 0;
                            tmr :> start;
                        }
                        // If we are paused, but we weren't last time, stop the timer.
                        else if(paused == 1 && wasPaused == 0){
                            tmr :> end;
                            actualTime += end-start;
                            wasPaused = 1;
                        }

                        toDistributor <: paused;
                        if(paused == 0) rounds ++;
                    }

                    if(paused == 0) toleds <: 2; // If not paused, flash to indicate processing.
                    else 			toleds <: 3; // If paused, show Red light
                    break;
                }

                break;

            case fromAccelerometer :> input:
                // If we hear from the accelerometer, it means we toggle the pause.
                // However, to avoid getting out of sync, we just pass the pause value instead of a toggle.

                switch(input){
                case 0: // Set paused off
                    paused = 0;
                    break;
                case 1: // Set paused on
                    paused = 1;
                    printf("Pausing... processed %d rounds so far in %u seconds.\n", rounds, actualTime/100000000);fflush(stdout);
                    break;
                }

                break;

            case fromButtonListener :> input:
                if(input == 13) // 13: button sw2
                    toExport = 1;
                break;
        }

        // Every 5 rounds, update the current timer, as the tmr can only count for ~42 seconds according to the documentation.
        if(rounds % 5 == 0){
            tmr :> end;
            actualTime += end-start;
            tmr :> start;
        }
    }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Buttons & LEDs
//
/////////////////////////////////////////////////////////////////////////////////////////

// Decodes LED pattern
void controlLEDs(out port p, chanend fromController) {
    int state, toPort;

    while(1){
        fromController :> state;

        switch(state){

        case 0: toPort = 0; break; // Nothing

        case 1: toPort = 4; break; // Separate green light

        case 2:
            toPort = 0;
            p <: toPort;
            waitMoment(500000);
            toPort = 1;			   // Normal green light
            p <: toPort;
            waitMoment(500000);
            toPort = 0;
            p <: toPort;
            waitMoment(500000);
            toPort = 1;
            break;

        case 3: toPort = 8;	break; // Red light
        case 4: toPort = 2; break; // Blue light
        }

        p <: toPort;
    }
}

//READ BUTTONS and send button pattern to userAnt
void buttonListener(in port b, chanend toController) {
    int r;

    while (1) {
        b when pinseq(15)  :> r;    	// check that no button is pressed
        b when pinsneq(15) :> r;    	// check if some buttons are pressed
        if ((r==13) || (r==14))     	// if either button is pressed - 13: SW2, 14: button SW1
            toController <: r;      	// send button pattern to controller
    }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Initialise and read orientation, send first tilt event to channel
//
/////////////////////////////////////////////////////////////////////////////////////////
void orientation(client interface i2c_master_if i2c, chanend toController) {
    i2c_regop_res_t result;
    char status_data = 0;
    int tilted = 0;

    // Configure FXOS8700EQ
    result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_XYZ_DATA_CFG_REG, 0x01);
    if (result != I2C_REGOP_SUCCESS) {
        printf("I2C write reg failed\n");
    }
  
    // Enable FXOS8700EQ
    result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_CTRL_REG_1, 0x01);
    if (result != I2C_REGOP_SUCCESS) {
        printf("I2C write reg failed\n");
    }

    //Probe the orientation x-axis forever

    while(1){
        //check until new orientation data is available
        do {
            status_data = i2c.read_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_DR_STATUS, result);
        } while (!status_data & 0x08);

        //get new x-axis tilt value
        int x = read_acceleration(i2c, FXOS8700EQ_OUT_X_MSB);

        //send signal to distributor after first tilt
        if (tilted == 0 && x > 30) {
            toController <: 1;
            tilted = 1;
        }
        else if(tilted == 1 && x < 30){
            toController <: 0;
            tilted = 0;
        }
    }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Orchestrate concurrent system and start up all threads
//
/////////////////////////////////////////////////////////////////////////////////////////
int main(void) {

    i2c_master_if i2c[1];               //interface to orientation

    chan c_orientation, c_buttonListener, c_distributor, c_leds, c_worker[PTNM];    //extend your channel definitions here

    par {
        // Tiles not all being 0 are so that the worker threads can be spread over both cores
        on tile[0]: i2c_master(i2c, 1, p_scl, p_sda, 10);                   //server thread providing orientation data
        on tile[0]: orientation(i2c[0], c_orientation);                     //client thread reading orientation data
        on tile[0]: buttonListener(buttons, c_buttonListener);              //thread reading button information data
        on tile[0]: controlLEDs(leds, c_leds);                              //thread setting LEDs
        on tile[1]: distributor(c_distributor, c_worker);                   //thread to coordinate work on image

        par(int i = 0; i < PTNM; i ++) {                        // threads to process image
            on tile[(i+1)%2]: imgPartWorker(c_worker[i]);
        }

        on tile[1]: controller(c_distributor, c_orientation, c_buttonListener, c_leds); // Controller thread.
    }

    return 0;
}
